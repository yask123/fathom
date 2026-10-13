// Runs the tools Fathom stands on (gh, git, claude) as child processes, with the environment a Terminal window
// would give them, which a Finder-launched app lacks.

import Foundation

struct ShellError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Where gh, git and claude usually live, for when the login shell can't be asked.
    static let commonPaths: [String] = {
        var paths = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.claude/local", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims",
        ]
        // nvm keeps one bin per Node version; the newest first.
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        return paths
    }()

    static var searchPath: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    static func which(_ name: String) -> String? {
        searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What child processes see: the user's own shell environment once it's known (PATH, proxies, GH_HOST,
    /// CLAUDE_CONFIG_DIR…), so gh and claude behave as they do in Terminal, and never stop to ask anything.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in loginEnvironment ?? [:] where !terminalOnly.contains(key) {
            env[key] = value
        }
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        env["PATH"] = (path + commonPaths).uniqued().joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private static let terminalOnly: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "ITERM_SESSION_ID", "COLORTERM", "TMUX", "TMUX_PANE", "STY", "LINES", "COLUMNS",
    ]

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var env: [String: String]?
    }
    private static let box = Box()

    private static var loginEnvironment: [String: String]? {
        box.lock.withLock { box.env }
    }

    /// An app opened from Finder starts with almost no environment. Ask the user's login shell once,
    /// the way Terminal would start it, and keep what it says. Gives up quietly after a few seconds.
    static func loadLoginEnvironment() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? "/bin/zsh"
        // The answer goes to a file, not a pipe: something started from a .zshrc can hold a pipe open forever.
        let file = FileManager.default.temporaryDirectory.appending(path: "fathom-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i reads .zshrc, where nvm, mise and most PATH edits live; -l the profile files.
        process.arguments = ["-ilc", "/usr/bin/env -0 > '\(file.path)'"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = AsyncStream<Void> { cont in
            process.terminationHandler = { _ in
                cont.yield()
                cont.finish()
            }
        }
        do { try process.run() } catch { return }
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(8))
            if process.isRunning { process.terminate() }
        }
        for await _ in exited {}
        watchdog.cancel()
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return }
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let pair = String(decoding: entry, as: UTF8.self)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard env["PATH"] != nil else { return }
        box.lock.withLock { box.env = env }
    }

    struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let status: Int32
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var errorText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Runs to completion. Throws on launch failure or cancellation, not on a non-zero exit.
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, input: Data? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 120) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = environment ?? Shell.environment
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inp
        let exited = AsyncStream<Void> { cont in
            process.terminationHandler = { _ in
                cont.yield()
                cont.finish()
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            if let input {
                let writer = inp.fileHandleForWriting
                Thread.detachNewThread {
                    // The throwing write: a child that exits early gives EPIPE here instead of an exception.
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
            }
            async let o = readAll(out.fileHandleForReading)
            async let e = readAll(err.fileHandleForReading)
            let watchdog = Task.detached {
                try await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
            }
            let (od, ed) = await (o, e)
            for await _ in exited {}
            watchdog.cancel()
            try Task.checkCancellation()
            return Output(stdout: od, stderr: ed, status: process.terminationStatus)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Reads a pipe to the end on its own thread, so blocking reads never hold Swift's shared executor threads.
    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    /// Streams stdout line by line. Finishes with an error carrying stderr when the process fails.
    static func lines(_ exe: String, _ args: [String], cwd: URL? = nil, input: Data? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            process.environment = environment
            if let cwd { process.currentDirectoryURL = cwd }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = input == nil ? FileHandle.nullDevice : inp

            let splitter = LineSplitter { continuation.yield($0) }
            let errors = DataBox()
            let outDone = DispatchSemaphore(value: 0)
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    splitter.flush()
                    outDone.signal()
                } else {
                    splitter.feed(chunk)
                }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { errors.append(chunk) }
            }
            process.terminationHandler = { p in
                DispatchQueue.global().async {
                    _ = outDone.wait(timeout: .now() + 5)
                    if p.terminationStatus != 0 && p.terminationReason != .uncaughtSignal {
                        let text = errors.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.finish(throwing: ShellError(message: text.isEmpty ? "exited with \(p.terminationStatus)" : String(text.suffix(600))))
                    } else {
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
                if let input {
                    let writer = inp.fileHandleForWriting
                    Thread.detachNewThread {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Splits a byte stream into lines on a lock, for readabilityHandler callbacks.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let emit: (String) -> Void

    init(_ emit: @escaping (String) -> Void) { self.emit = emit }

    func feed(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}

final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
