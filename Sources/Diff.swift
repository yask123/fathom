// Unified diff → files → hunks → lines, with stable ids (f3h2) that Claude refers to,
// and a quiet judgement of which files are mechanical noise.

import Foundation

enum LineKind: Sendable {
    case context, add, del, meta
}

struct DiffLine: Hashable, Sendable {
    var kind: LineKind
    var text: String
    var old: Int?
    var new: Int?
}

struct Hunk: Identifiable, Sendable {
    var id: String
    var fileId: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var section: String
    var lines: [DiffLine] = []
    var additions = 0
    var deletions = 0
}

enum FileStatus: String, Sendable {
    case added, deleted, modified, renamed
}

enum Noise: String, Sendable {
    case lockfile, generated, vendored, snapshot, binary, project, minified, renamed, asset

    var word: String {
        switch self {
        case .lockfile: "lockfile"
        case .generated: "generated"
        case .vendored: "vendored"
        case .snapshot: "snapshot"
        case .binary: "binary"
        case .project: "project file"
        case .minified: "minified"
        case .renamed: "rename only"
        case .asset: "asset"
        }
    }
}

struct DiffFile: Identifiable, Sendable {
    var id: String
    var index: Int
    var oldPath: String
    var newPath: String
    var status: FileStatus = .modified
    var isBinary = false
    var hunks: [Hunk] = []
    var additions = 0
    var deletions = 0
    var noise: Noise?
    var language: Language = .plain

    var path: String { status == .deleted ? oldPath : newPath }
    var name: String { (path as NSString).lastPathComponent }
    var dir: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d + "/"
    }
}

struct ParsedDiff: Sendable {
    var files: [DiffFile] = []
    private(set) var hunkIndex: [String: (file: Int, hunk: Int)] = [:]

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    var signalFiles: [DiffFile] { files.filter { $0.noise == nil } }
    var noiseFiles: [DiffFile] { files.filter { $0.noise != nil } }

    func hunk(_ id: String) -> Hunk? {
        guard let p = hunkIndex[id] else { return nil }
        return files[p.file].hunks[p.hunk]
    }

    func file(ofHunk id: String) -> DiffFile? {
        guard let p = hunkIndex[id] else { return nil }
        return files[p.file]
    }

    func file(path: String) -> DiffFile? {
        files.first { $0.path == path || $0.newPath == path || $0.oldPath == path }
            ?? files.first { $0.path.hasSuffix("/" + path) || path.hasSuffix("/" + $0.path) }
    }

    /// The line inside a hunk that best matches an anchor Claude copied from it.
    func lineIndex(hunk id: String, anchor: String) -> Int? {
        guard let h = hunk(id) else { return nil }
        let needle = anchor.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        if let i = h.lines.firstIndex(where: { $0.kind != .del && $0.text.contains(needle) }) { return i }
        if let i = h.lines.firstIndex(where: { $0.text.contains(needle) }) { return i }
        let squeezed = needle.replacingOccurrences(of: " ", with: "")
        return h.lines.firstIndex { $0.text.replacingOccurrences(of: " ", with: "").contains(squeezed) }
    }

    mutating func reindex() {
        hunkIndex = [:]
        for (fi, f) in files.enumerated() {
            for (hi, h) in f.hunks.enumerated() { hunkIndex[h.id] = (fi, hi) }
        }
    }
}

enum DiffParser {
    static func parse(_ text: String) -> ParsedDiff {
        var diff = ParsedDiff()
        var file: DiffFile?
        var hunk: Hunk?
        var oldNo = 0, newNo = 0

        func closeHunk() {
            if let h = hunk, file != nil { file!.hunks.append(h) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if var f = file {
                f.additions = f.hunks.reduce(0) { $0 + $1.additions }
                f.deletions = f.hunks.reduce(0) { $0 + $1.deletions }
                f.language = Language(path: f.path)
                f.noise = noise(for: f)
                diff.files.append(f)
            }
            file = nil
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("diff --git ") {
                closeFile()
                let index = diff.files.count + 1
                let (a, b) = headerPaths(line)
                file = DiffFile(id: "f\(index)", index: index, oldPath: a, newPath: b)
                continue
            }
            guard file != nil else { continue }

            if hunk == nil || !(line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\\") || line.isEmpty) {
                if line.hasPrefix("@@") {
                    closeHunk()
                    let h = parseHunkHeader(line, fileId: file!.id, index: file!.hunks.count + 1)
                    oldNo = h.oldStart
                    newNo = h.newStart
                    hunk = h
                    continue
                }
                if line.hasPrefix("new file mode") { file!.status = .added; continue }
                if line.hasPrefix("deleted file mode") { file!.status = .deleted; continue }
                if line.hasPrefix("rename from ") { file!.status = .renamed; file!.oldPath = unquote(String(line.dropFirst(12))); continue }
                if line.hasPrefix("rename to ") { file!.newPath = unquote(String(line.dropFirst(10))); continue }
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { file!.isBinary = true; continue }
                if line.hasPrefix("--- ") {
                    let p = cleanPath(String(line.dropFirst(4)))
                    if p == "/dev/null" { file!.status = .added } else { file!.oldPath = p }
                    continue
                }
                if line.hasPrefix("+++ ") {
                    let p = cleanPath(String(line.dropFirst(4)))
                    if p == "/dev/null" { file!.status = .deleted } else { file!.newPath = p }
                    continue
                }
                continue
            }

            // Inside a hunk.
            if line.hasPrefix("@@") {
                closeHunk()
                let h = parseHunkHeader(line, fileId: file!.id, index: file!.hunks.count + 1)
                oldNo = h.oldStart
                newNo = h.newStart
                hunk = h
                continue
            }
            if line.hasPrefix("+") {
                hunk!.lines.append(DiffLine(kind: .add, text: String(line.dropFirst()), old: nil, new: newNo))
                hunk!.additions += 1
                newNo += 1
            } else if line.hasPrefix("-") {
                hunk!.lines.append(DiffLine(kind: .del, text: String(line.dropFirst()), old: oldNo, new: nil))
                hunk!.deletions += 1
                oldNo += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — not worth a row.
            } else if line.isEmpty {
                // A trailing empty split, or a context line whose single space was stripped.
                if oldNo < hunk!.oldStart + hunk!.oldCount || newNo < hunk!.newStart + hunk!.newCount {
                    hunk!.lines.append(DiffLine(kind: .context, text: "", old: oldNo, new: newNo))
                    oldNo += 1
                    newNo += 1
                }
            } else {
                hunk!.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: oldNo, new: newNo))
                oldNo += 1
                newNo += 1
            }
        }
        closeFile()
        diff.reindex()
        return diff
    }

    private static func parseHunkHeader(_ line: String, fileId: String, index: Int) -> Hunk {
        // @@ -a,b +c,d @@ section
        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1, section = ""
        let parts = line.components(separatedBy: "@@")
        if parts.count >= 2 {
            for token in parts[1].split(separator: " ") {
                let nums = token.dropFirst().split(separator: ",").compactMap { Int($0) }
                if token.hasPrefix("-") {
                    oldStart = nums.first ?? 0
                    oldCount = nums.count > 1 ? nums[1] : 1
                } else if token.hasPrefix("+") {
                    newStart = nums.first ?? 0
                    newCount = nums.count > 1 ? nums[1] : 1
                }
            }
        }
        if parts.count >= 3 {
            section = parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
        }
        return Hunk(id: "\(fileId)h\(index)", fileId: fileId, oldStart: oldStart, oldCount: oldCount,
                    newStart: newStart, newCount: newCount, section: section)
    }

    private static func headerPaths(_ line: String) -> (String, String) {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            let parts = rest.components(separatedBy: "\" \"")
            if parts.count == 2 { return (cleanPath(parts[0] + "\""), cleanPath("\"" + parts[1])) }
        }
        // a/x b/x — split in the middle when both halves agree, which handles spaces in paths.
        if let r = rest.range(of: " b/", options: .backwards) {
            return (cleanPath(String(rest[..<r.lowerBound])), cleanPath("b/" + rest[r.upperBound...]))
        }
        return (cleanPath(rest), cleanPath(rest))
    }

    private static func cleanPath(_ p: String) -> String {
        var s = unquote(p.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("a/") || s.hasPrefix("b/") { s = String(s.dropFirst(2)) }
        if let tab = s.firstIndex(of: "\t") { s = String(s[..<tab]) }
        return s
    }

    /// Git quotes unusual paths C-style: "caf\303\251.txt" → café.txt.
    private static func unquote(_ p: String) -> String {
        guard p.count >= 2, p.hasPrefix("\""), p.hasSuffix("\"") else { return p }
        var bytes: [UInt8] = []
        var it = Array(p.utf8.dropFirst().dropLast())[...]
        while let b = it.popFirst() {
            guard b == 0x5C, let n = it.first else { bytes.append(b); continue }
            switch n {
            case 0x30...0x37:
                var v = 0, count = 0
                while count < 3, let d = it.first, (0x30...0x37).contains(d) {
                    v = v * 8 + Int(d - 0x30)
                    it.removeFirst()
                    count += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: v))
            case 0x6E: bytes.append(0x0A); it.removeFirst()
            case 0x74: bytes.append(0x09); it.removeFirst()
            default: bytes.append(n); it.removeFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Noise

    static let lockfiles: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
        "Cargo.lock", "Gemfile.lock", "Podfile.lock", "poetry.lock", "Pipfile.lock", "uv.lock", "composer.lock",
        "go.sum", "mix.lock", "Package.resolved", "flake.lock", "pubspec.lock", "gradle.lockfile", "packages.lock.json",
    ]
    static let assetExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf", "mp3", "mp4", "mov", "wav", "ttf", "otf", "woff", "woff2",
        "zip", "gz", "jar", "car", "heic", "tiff", "psd", "sketch",
    ]

    static func noise(for f: DiffFile) -> Noise? {
        let path = f.path
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let lower = path.lowercased()
        if f.isBinary { return assetExtensions.contains(ext) ? .asset : .binary }
        if lockfiles.contains(name) { return .lockfile }
        if ext == "pbxproj" || ext == "xcscheme" || name == "contents.xcworkspacedata" || ext == "xcstrings" { return .project }
        if lower.hasSuffix(".min.js") || lower.hasSuffix(".min.css") || ext == "map" { return .minified }
        if lower.contains("__snapshots__/") || ext == "snap" { return .snapshot }
        if lower.hasPrefix("vendor/") || lower.contains("/vendor/") || lower.contains("node_modules/") || lower.hasPrefix("third_party/")
            || lower.hasPrefix("pods/") || lower.contains("/pods/") { return .vendored }
        if lower.contains(".generated.") || lower.contains("/generated/") || lower.contains("__generated__/") || lower.hasSuffix(".pb.go")
            || lower.hasSuffix("_pb2.py") || lower.hasSuffix(".g.dart") || lower.hasSuffix(".freezed.dart") || lower.hasSuffix(".gen.ts")
            || lower.hasPrefix("dist/") || lower.contains("/dist/") { return .generated }
        if assetExtensions.contains(ext) { return .asset }
        if f.status == .renamed && f.hunks.isEmpty { return .renamed }
        return nil
    }
}

// MARK: - Languages

enum Language: String, Sendable {
    case swift, typescript, javascript, python, ruby, go, rust, java, kotlin, c, cpp, objc, csharp, php, dart, scala
    case css, html, json, yaml, toml, markdown, shell, sql, lua, elixir, xml, plain

    init(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift": self = .swift
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "py", "pyi": self = .python
        case "rb", "rake", "gemspec": self = .ruby
        case "go": self = .go
        case "rs": self = .rust
        case "java": self = .java
        case "kt", "kts": self = .kotlin
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx": self = .cpp
        case "m", "mm": self = .objc
        case "cs": self = .csharp
        case "php": self = .php
        case "dart": self = .dart
        case "scala": self = .scala
        case "css", "scss", "sass", "less": self = .css
        case "html", "htm", "vue", "svelte", "erb", "astro": self = .html
        case "json", "jsonc": self = .json
        case "yml", "yaml": self = .yaml
        case "toml": self = .toml
        case "md", "mdx", "markdown": self = .markdown
        case "sh", "bash", "zsh", "fish": self = .shell
        case "sql": self = .sql
        case "lua": self = .lua
        case "ex", "exs": self = .elixir
        case "xml", "plist", "storyboard", "xib", "svg": self = .xml
        default:
            if ["dockerfile", "makefile", "gemfile", "rakefile", "podfile", "brewfile", "procfile"].contains(name) {
                self = name == "gemfile" || name == "rakefile" || name == "podfile" || name == "brewfile" ? .ruby : .shell
            } else {
                self = .plain
            }
        }
    }

    var label: String {
        switch self {
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .objc: "Objective-C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .plain: ""
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}
