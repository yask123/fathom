// Quiet syntax colour for diff lines, and word-level change marks inside edited lines.

import AppKit
import SwiftUI

enum CodeInk {
    static let text = Color(hex: 0xD3DAE5)
    static let keyword = Color(hex: 0xC5A8FF)
    static let type = Color(hex: 0x82D9E6)
    static let function = Color(hex: 0x8FBBFF)
    static let string = Color(hex: 0xE9C590)
    static let number = Color(hex: 0xF2A988)
    static let comment = Color(hex: 0x5F6A7C)
    static let attr = Color(hex: 0xF3A3BC)
}

enum Highlighter {
    private struct Spec {
        var regex: NSRegularExpression
        var keywords: Set<String>
        var groups: [String] {
            let p = regex.pattern
            return ["comment", "string", "number", "attr", "keyword", "type", "function", "word"].filter { p.contains("(?<\($0)>") }
        }
        var caseInsensitive = false
        var block: (open: String, close: String)?
        var tripleQuote = false
    }

    private static let cLike = #"(?<comment>//.*$|/\*.*?(\*/|$))|(?<string>"{3}.*?(?:"{3}|$)|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|`(?:\\.|[^`\\])*`?)|(?<number>\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)|(?<attr>@[A-Za-z_][\w.]*|#[A-Za-z_]\w*)|(?<word>[A-Za-z_$][\w$]*)"#
    private static let hashLike = #"(?<comment>#.*$)|(?<string>[rbfuRBFU]{0,2}"{3}.*?(?:"{3}|$)|[rbfuRBFU]{0,2}'{3}.*?(?:'{3}|$)|[rbfuRBFU]{0,2}"(?:\\.|[^"\\])*"?|[rbfuRBFU]{0,2}'(?:\\.|[^'\\])*'?)|(?<number>\b\d[\d_]*(?:\.\d+)?\b)|(?<attr>@[A-Za-z_][\w.]*|:[A-Za-z_]\w*[?!]?|\$\{?[A-Za-z_]\w*\}?)|(?<word>[A-Za-z_][\w?!]*)"#
    private static let dashLike = #"(?<comment>--.*$)|(?<string>"(?:\\.|[^"\\])*"?|'(?:''|[^'])*'?)|(?<number>\b\d+(?:\.\d+)?\b)|(?<word>[A-Za-z_][\w]*)"#
    private static let yamlLike = #"(?<comment>(?:^|\s)#.*$)|(?<attr>^\s*-?\s*[\w.\-/"']+(?=\s*[:=]))|(?<string>"(?:\\.|[^"\\])*"?|'(?:''|[^'])*'?)|(?<number>\b\d+(?:\.\d+)?\b)|(?<word>\b(?:true|false|null|yes|no|on|off)\b)"#
    private static let jsonLike = #"(?<attr>"(?:\\.|[^"\\])*"(?=\s*:))|(?<string>"(?:\\.|[^"\\])*"?)|(?<number>-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|(?<word>\b(?:true|false|null)\b)"#
    private static let cssLike = #"(?<comment>/\*.*?(\*/|$))|(?<string>"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?)|(?<attr>[\w-]+(?=\s*:[^:]))|(?<number>#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|rem|em|%|vh|vw|s|ms|deg|fr)?\b)|(?<word>[A-Za-z_-][\w-]*)"#
    private static let markupLike = #"(?<comment><!--.*?(-->|$))|(?<string>"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?)|(?<keyword></?[A-Za-z][\w:.-]*|/?>)|(?<attr>\b[\w:@.-]+(?==))"#
    private static let markdownLike = #"(?<keyword>^\s{0,3}#{1,6}\s.*$)|(?<string>`[^`]*`?)|(?<type>\*\*[^*]+\*\*|__[^_]+__)|(?<function>\[[^\]]*\]\([^)]*\)?)|(?<attr>^\s*(?:[-*+]|\d+\.)\s)"#

    private static let swiftWords: Set<String> = ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "return", "if", "else", "guard", "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "fallthrough", "where", "throw", "throws", "rethrows", "try", "catch", "do", "defer", "as", "is", "nil", "true", "false", "self", "Self", "super", "init", "deinit", "subscript", "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating", "nonmutating", "lazy", "weak", "unowned", "inout", "some", "any", "async", "await", "actor", "nonisolated", "isolated", "typealias", "associatedtype", "operator", "convenience", "required", "optional", "dynamic", "get", "set", "willSet", "didSet", "macro", "consuming", "borrowing", "sending", "package"]
    private static let jsWords: Set<String> = ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "null", "undefined", "true", "false", "try", "catch", "finally", "throw", "async", "await", "yield", "import", "export", "from", "as", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "abstract", "declare", "namespace", "keyof", "infer", "is", "satisfies", "void", "never", "unknown", "any", "get", "set"]
    private static let pythonWords: Set<String> = ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True", "False", "try", "except", "finally", "raise", "with", "as", "import", "from", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "async", "await", "match", "case", "self"]
    private static let rubyWords: Set<String> = ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "then", "case", "when", "nil", "true", "false", "self", "super", "and", "or", "not", "alias", "require", "require_relative", "attr_accessor", "attr_reader", "attr_writer", "private", "protected", "public", "lambda", "proc", "new", "include", "extend"]
    private static let goWords: Set<String> = ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "fallthrough", "select", "nil", "true", "false", "make", "new", "len", "cap", "append", "error", "string", "int", "int64", "bool", "byte", "rune", "float64", "any"]
    private static let rustWords: Set<String> = ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "in", "where", "pub", "use", "mod", "crate", "self", "Self", "super", "return", "if", "else", "match", "loop", "while", "break", "continue", "as", "ref", "move", "async", "await", "dyn", "unsafe", "type", "true", "false", "Some", "None", "Ok", "Err"]
    private static let jvmWords: Set<String> = ["class", "interface", "enum", "extends", "implements", "public", "private", "protected", "internal", "static", "final", "abstract", "void", "int", "long", "short", "byte", "char", "boolean", "double", "float", "new", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally", "throw", "throws", "this", "super", "null", "true", "false", "import", "package", "var", "val", "fun", "object", "companion", "data", "sealed", "override", "suspend", "when", "is", "in", "out", "lateinit", "const", "struct", "typedef", "sizeof", "include", "define", "namespace", "using", "template", "typename", "auto", "virtual", "inline", "extern", "unsigned", "signed", "nullptr", "self", "id", "nil", "YES", "NO", "function", "echo", "async", "await", "yield", "late", "required", "def", "lazy", "implicit", "match"]
    private static let sqlWords: Set<String> = ["select", "from", "where", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "add", "drop", "index", "primary", "key", "foreign", "references", "not", "null", "default", "unique", "and", "or", "in", "is", "as", "distinct", "count", "case", "when", "then", "else", "end", "begin", "commit", "rollback", "returning", "with", "union", "all", "exists", "column", "constraint", "cascade", "if"]
    private static let shellWords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "export", "local", "readonly", "set", "unset", "echo", "exit", "source", "alias", "cd", "true", "false", "FROM", "RUN", "COPY", "CMD", "ENV", "WORKDIR", "ENTRYPOINT", "ARG", "EXPOSE"]
    private static let luaWords: Set<String> = ["local", "function", "end", "if", "then", "else", "elseif", "for", "in", "do", "while", "repeat", "until", "return", "break", "nil", "true", "false", "and", "or", "not", "require"]
    private static let elixirWords: Set<String> = ["def", "defp", "defmodule", "do", "end", "if", "else", "unless", "case", "cond", "with", "fn", "when", "import", "alias", "require", "use", "true", "false", "nil"]

    nonisolated(unsafe) private static var cache: [Language: Spec?] = [:]
    private static let lock = NSLock()

    private static func spec(_ lang: Language) -> Spec? {
        lock.lock()
        defer { lock.unlock() }
        if let s = cache[lang] { return s }
        let s = makeSpec(lang)
        cache[lang] = s
        return s
    }

    private static func re(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static func makeSpec(_ lang: Language) -> Spec? {
        switch lang {
        case .swift: Spec(regex: re(cLike), keywords: swiftWords, block: ("/*", "*/"), tripleQuote: true)
        case .typescript, .javascript: Spec(regex: re(cLike), keywords: jsWords, block: ("/*", "*/"))
        case .go: Spec(regex: re(cLike), keywords: goWords, block: ("/*", "*/"))
        case .rust: Spec(regex: re(cLike), keywords: rustWords, block: ("/*", "*/"))
        case .java, .kotlin, .c, .cpp, .objc, .csharp, .php, .dart, .scala:
            Spec(regex: re(cLike), keywords: jvmWords, block: ("/*", "*/"), tripleQuote: lang == .kotlin || lang == .scala || lang == .dart)
        case .python: Spec(regex: re(hashLike), keywords: pythonWords, tripleQuote: true)
        case .ruby: Spec(regex: re(hashLike), keywords: rubyWords)
        case .shell: Spec(regex: re(hashLike), keywords: shellWords)
        case .elixir: Spec(regex: re(hashLike), keywords: elixirWords, tripleQuote: true)
        case .sql: Spec(regex: re(dashLike), keywords: sqlWords, caseInsensitive: true, block: ("/*", "*/"))
        case .lua: Spec(regex: re(dashLike), keywords: luaWords)
        case .yaml, .toml: Spec(regex: re(yamlLike), keywords: ["true", "false", "null", "yes", "no", "on", "off"])
        case .json: Spec(regex: re(jsonLike), keywords: ["true", "false", "null"])
        case .css: Spec(regex: re(cssLike), keywords: ["important", "media", "supports", "keyframes", "import", "from", "to"], block: ("/*", "*/"))
        case .html, .xml: Spec(regex: re(markupLike), keywords: [], block: ("<!--", "-->"))
        case .markdown: Spec(regex: re(markdownLike), keywords: [])
        case .plain: nil
        }
    }

    /// Highlights a run of lines in order, carrying block comments and triple-quoted strings across them.
    static func highlight(_ lines: [String], _ lang: Language) -> [AttributedString] {
        guard let spec = spec(lang) else {
            return lines.map { plain($0) }
        }
        var inBlock = false
        var triple: String?   // the open triple-quote delimiter, while inside one
        return lines.map { line in
            var out = plain(line)
            var start = line.startIndex

            // Continue a block comment or a multi-line string from earlier lines.
            if inBlock, let b = spec.block {
                if let close = line.range(of: b.close) {
                    paint(&out, line, line.startIndex..<close.upperBound, CodeInk.comment)
                    start = close.upperBound
                    inBlock = false
                } else {
                    paint(&out, line, line.startIndex..<line.endIndex, CodeInk.comment)
                    return out
                }
            } else if let delim = triple {
                if let close = line.range(of: delim) {
                    paint(&out, line, line.startIndex..<close.upperBound, CodeInk.string)
                    start = close.upperBound
                    triple = nil
                } else {
                    paint(&out, line, line.startIndex..<line.endIndex, CodeInk.string)
                    return out
                }
            }

            let rest = String(line[start...])
            let offset = line.distance(from: line.startIndex, to: start)
            let ns = rest as NSString
            let matches = spec.regex.matches(in: rest, range: NSRange(location: 0, length: ns.length))
            let groups = spec.groups
            let inks: [(String, Color)] = [("comment", CodeInk.comment), ("string", CodeInk.string), ("number", CodeInk.number),
                                           ("attr", CodeInk.attr), ("keyword", CodeInk.keyword), ("type", CodeInk.type),
                                           ("function", CodeInk.function)].filter { groups.contains($0.0) }
            let hasWord = groups.contains("word")
            for m in matches {
                for (group, ink) in inks {
                    let r = m.range(withName: group)
                    guard r.location != NSNotFound, let range = Range(r, in: rest) else { continue }
                    paint(&out, line, shift(range, in: rest, line: line, offset: offset), ink)
                    if group == "comment", let b = spec.block, rest[range].hasPrefix(b.open), !rest[range].dropFirst(b.open.count).contains(b.close) {
                        inBlock = true
                    }
                    if group == "string", spec.tripleQuote {
                        let text = rest[range].drop { "rbfuRBFU".contains($0) }
                        for delim in [String(repeating: "\"", count: 3), String(repeating: "'", count: 3)]
                        where text.hasPrefix(delim) && (text.count < 6 || !text.hasSuffix(delim)) {
                            triple = delim
                        }
                    }
                }
                let w = hasWord ? m.range(withName: "word") : NSRange(location: NSNotFound, length: 0)
                if w.location != NSNotFound, let range = Range(w, in: rest) {
                    let word = String(rest[range])
                    let key = spec.caseInsensitive ? word.lowercased() : word
                    let full = shift(range, in: rest, line: line, offset: offset)
                    if spec.keywords.contains(key) {
                        paint(&out, line, full, CodeInk.keyword)
                    } else if rest[range.upperBound...].first == "(" {
                        paint(&out, line, full, CodeInk.function)
                    } else if let first = word.first, first.isUppercase, word.count > 1, lang != .sql {
                        paint(&out, line, full, CodeInk.type)
                    }
                }
            }
            // A markup block comment that opens and doesn't close on this line.
            if let b = spec.block, lang == .html || lang == .xml, let open = rest.range(of: b.open, options: .backwards),
               !rest[open.upperBound...].contains(b.close) {
                inBlock = true
            }
            return out
        }
    }

    static func plain(_ line: String) -> AttributedString {
        var a = AttributedString(line)
        a.foregroundColor = CodeInk.text
        return a
    }

    private static func shift(_ r: Range<String.Index>, in rest: String, line: String, offset: Int) -> Range<String.Index> {
        let lo = line.index(line.startIndex, offsetBy: offset + rest.distance(from: rest.startIndex, to: r.lowerBound))
        let hi = line.index(lo, offsetBy: rest.distance(from: r.lowerBound, to: r.upperBound))
        return lo..<hi
    }

    private static func paint(_ a: inout AttributedString, _ line: String, _ r: Range<String.Index>, _ color: Color) {
        let lo = line.distance(from: line.startIndex, to: r.lowerBound)
        let len = line.distance(from: r.lowerBound, to: r.upperBound)
        guard len > 0 else { return }
        let start = a.index(a.startIndex, offsetByCharacters: lo)
        let end = a.index(start, offsetByCharacters: len)
        a[start..<end].foregroundColor = color
    }

    /// Marks changed character spans with a background.
    static func mark(_ a: inout AttributedString, spans: [Range<Int>], color: Color) {
        let count = a.characters.count
        for s in spans where s.lowerBound < count {
            let start = a.index(a.startIndex, offsetByCharacters: s.lowerBound)
            let end = a.index(a.startIndex, offsetByCharacters: min(s.upperBound, count))
            a[start..<end].backgroundColor = color
        }
    }
}

/// Word-level differences between a removed line and the added line that replaced it.
enum Intraline {
    /// Changed character spans keyed by line index within the hunk.
    static func spans(for lines: [DiffLine]) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .del else { i += 1; continue }
            var dels: [Int] = []
            while i < lines.count, lines[i].kind == .del { dels.append(i); i += 1 }
            var adds: [Int] = []
            while i < lines.count, lines[i].kind == .add { adds.append(i); i += 1 }
            for k in 0..<min(dels.count, adds.count) {
                let a = lines[dels[k]].text, b = lines[adds[k]].text
                guard let (da, db) = diff(a, b) else { continue }
                if !da.isEmpty { result[dels[k]] = da }
                if !db.isEmpty { result[adds[k]] = db }
            }
        }
        return result
    }

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var curIsWord = false
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if isWord {
                if curIsWord { cur.append(ch) } else {
                    if !cur.isEmpty { out.append(cur) }
                    cur = String(ch)
                    curIsWord = true
                }
            } else {
                if !cur.isEmpty { out.append(cur) }
                cur = ""
                curIsWord = false
                out.append(String(ch))
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func diff(_ a: String, _ b: String) -> ([Range<Int>], [Range<Int>])? {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty, ta.count < 400, tb.count < 400 else { return nil }
        let n = ta.count, m = tb.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for x in stride(from: n - 1, through: 0, by: -1) {
            for y in stride(from: m - 1, through: 0, by: -1) {
                dp[x][y] = ta[x] == tb[y] ? dp[x + 1][y + 1] + 1 : max(dp[x + 1][y], dp[x][y + 1])
            }
        }
        var keepA = [Bool](repeating: false, count: n), keepB = [Bool](repeating: false, count: m)
        var x = 0, y = 0
        while x < n, y < m {
            if ta[x] == tb[y] { keepA[x] = true; keepB[y] = true; x += 1; y += 1 }
            else if dp[x + 1][y] >= dp[x][y + 1] { x += 1 } else { y += 1 }
        }
        // Too different to be "the same line, edited": leave it to the line colours.
        let common = ta.indices.filter { keepA[$0] }.reduce(0) { $0 + ta[$1].count }
        let longest = max(a.count, b.count)
        guard longest > 0, Double(common) / Double(longest) >= 0.35 else { return nil }
        return (ranges(ta, keepA), ranges(tb, keepB))
    }

    private static func ranges(_ toks: [String], _ keep: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var pos = 0
        var open: Int?
        for (i, t) in toks.enumerated() {
            let space = t.allSatisfy(\.isWhitespace)
            if !keep[i] && !space {
                if open == nil { open = pos }
            } else if keep[i], let o = open {
                out.append(o..<pos)
                open = nil
            }
            pos += t.count
        }
        if let o = open { out.append(o..<pos) }
        return out
    }
}
