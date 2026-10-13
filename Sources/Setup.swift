// Fathom has no account of its own. It borrows two: the GitHub CLI's login, and Claude Code's.
// This file checks both, signs in to GitHub without leaving the app, and shows what's missing.

import AppKit
import SwiftUI

@MainActor
@Observable
final class Setup {
    enum GitHubState: Equatable {
        case checking
        case missing
        case signedOut
        case ready(String)         // the login
        case unreachable(String)   // signed in as far as we know, but GitHub didn't answer
    }

    enum ClaudeState: Equatable {
        case checking
        case missing
        case outdated(String)      // the version found
        case signedOut
        case ready(String)         // plan and account, or the version
    }

    var github: GitHubState = .checking
    var claude: ClaudeState = .checking
    var signIn: GitHubSignIn?
    private(set) var checked = false
    @ObservationIgnored private var checking = false
    /// Called when GitHub becomes usable after the first check, so the inbox can load.
    @ObservationIgnored var onGitHubReady: (() -> Void)?

    var ghReady: Bool {
        switch github {
        case .ready, .unreachable: true
        default: false
        }
    }

    var claudeReady: Bool {
        if case .ready = claude { return true }
        return false
    }

    var needsAttention: Bool { checked && !(ghReady && claudeReady) }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let wasReady = ghReady, firstCheck = !checked
        async let g = Self.probeGitHub()
        async let c = Self.probeClaude()
        var (gs, cs) = await (g, c)
        Self.applyFakes(&gs, &cs)
        withAnimation(Motion.soft) {
            github = gs
            claude = cs
            checked = true
        }
        if ghReady && !wasReady && !firstCheck { onGitHubReady?() }
    }

    func signInToGitHub() {
        signIn?.cancel()
        let flow = GitHubSignIn()
        flow.onFinish = { [weak self] ok in
            guard let self else { return }
            withAnimation(Motion.soft) { self.signIn = nil }
            if ok { Task { await self.check() } }
        }
        withAnimation(Motion.soft) { signIn = flow }
        flow.start()
    }

    /// Opens Terminal for the steps that need the user at a keyboard: signing in to Claude, updating it.
    func signInToClaude() {
        guard let exe = Claude.executable else { return }
        Task {
            let can = await Claude.abilities(exe)
            Terminal.run("\(Terminal.quote(exe)) \(can.commands.contains("auth") ? "auth login" : "")", title: "Sign in to Claude Code")
        }
    }

    func updateClaude() {
        guard let exe = Claude.executable else { return }
        Terminal.run("\(Terminal.quote(exe)) update", title: "Update Claude Code")
    }

    // MARK: Probes

    nonisolated static func probeGitHub() async -> GitHubState {
        guard let gh = Shell.which("gh") else { return .missing }
        guard let out = try? await Shell.run(gh, ["api", "user", "--jq", ".login"], timeout: 20) else {
            return .unreachable("The GitHub CLI didn't answer.")
        }
        let login = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.status == 0, !login.isEmpty { return .ready(login) }
        if GitHub.signedOut(out.errorText) { return .signedOut }
        return .unreachable(out.errorText.isEmpty ? "gh exited with \(out.status)" : String(out.errorText.prefix(200)))
    }

    nonisolated static func probeClaude() async -> ClaudeState {
        guard let exe = Claude.executable else { return .missing }
        let can = await Claude.abilities(exe)
        let printed = (try? await Shell.run(exe, ["--version"], timeout: 15))?.text ?? ""
        let version = printed.split(separator: " ").first.map(String.init) ?? ""
        guard can.isCurrent else { return .outdated(version) }
        // `claude auth status` came later than everything else Fathom uses. Without it, the first reading tells.
        if can.commands.contains("auth"), let out = try? await Shell.run(exe, ["auth", "status"], timeout: 20) {
            let j = J(data: out.stdout)
            if j["loggedIn"].exists {
                let provider = j["apiProvider"].stringOrNil ?? "firstParty"
                if !j["loggedIn"].bool && provider == "firstParty" { return .signedOut }
                var parts: [String] = []
                if let plan = j["subscriptionType"].stringOrNil, !plan.isEmpty {
                    parts.append("Claude \(plan.capitalized)")
                } else if provider != "firstParty" {
                    parts.append(provider.capitalized)
                }
                if let email = j["email"].stringOrNil, !email.isEmpty { parts.append(email) }
                return .ready(parts.isEmpty ? "Claude Code \(version)" : parts.joined(separator: " · "))
            }
        }
        return .ready("Claude Code \(version)")
    }

    /// FATHOM_SETUP=gh:signedOut,claude:missing shows a state without breaking the real tools, for screenshots.
    private static func applyFakes(_ gh: inout GitHubState, _ claude: inout ClaudeState) {
        guard let spec = ProcessInfo.processInfo.environment["FATHOM_SETUP"] else { return }
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: ":").map(String.init)
            guard kv.count == 2 else { continue }
            switch (kv[0], kv[1]) {
            case ("gh", "missing"): gh = .missing
            case ("gh", "signedOut"): gh = .signedOut
            case ("claude", "missing"): claude = .missing
            case ("claude", "outdated"): claude = .outdated("1.0.0")
            case ("claude", "signedOut"): claude = .signedOut
            default: break
            }
        }
    }
}

// MARK: - GitHub sign-in, in the app

/// `gh auth login --web`, with the one-time code shown here instead of in a terminal.
/// gh keeps the token, in the keychain, exactly as if the user had run it themselves.
@MainActor
@Observable
final class GitHubSignIn {
    enum Phase: Equatable {
        case starting
        case code(String)
        case failed(String)
    }

    var phase: Phase = .starting
    var copied = false
    @ObservationIgnored var onFinish: ((Bool) -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var lastLine = ""
    @ObservationIgnored private var cancelled = false

    static let devicePage = URL(string: "https://github.com/login/device")!

    func start() {
        guard let gh = Shell.which("gh") else {
            phase = .failed("The GitHub CLI isn't installed.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
        var env = Shell.environment
        env["GH_BROWSER"] = "/usr/bin/true"   // Fathom opens the page itself, once the code is on screen
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let splitter = LineSplitter { [weak self] line in
            Task { @MainActor in self?.read(line) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                splitter.flush()
            } else {
                splitter.feed(chunk)
            }
        }
        p.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                // Let the last lines land first, so a failure can say why.
                try? await Task.sleep(for: .milliseconds(200))
                self?.ended(status)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func read(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        lastLine = text
        if case .starting = phase, text.lowercased().contains("code"),
           let match = text.firstMatch(of: #/[A-Z0-9]{4}-[A-Z0-9]{4}/#) {
            withAnimation(Motion.soft) { phase = .code(String(match.output)) }
        }
    }

    private func ended(_ status: Int32) {
        process = nil
        guard !cancelled else { return }
        if status == 0 {
            onFinish?(true)
            return
        }
        let reason = lastLine.isEmpty || lastLine.contains("one-time code") ? "GitHub sign-in stopped (gh exited with \(status))." : lastLine
        withAnimation(Motion.soft) { phase = .failed(reason) }
    }

    func copyAndOpen() {
        guard case .code(let code) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        NSWorkspace.shared.open(Self.devicePage)
    }

    func cancel() {
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        process = nil
        onFinish?(false)
    }
}

// MARK: - Terminal

enum Terminal {
    /// Runs a command in a new Terminal window: a .command file, so no automation permission is needed.
    static func run(_ command: String, title: String) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Fathom", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(title).command")
        let script = """
        #!/bin/zsh
        clear
        printf '%s\\n\\n' \(quote(title))
        \(command)
        printf '\\nDone. Go back to Fathom; it checks again by itself. You can close this window.\\n'

        """
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Views

/// The home screen's card while something is missing.
struct SetupCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Fathom runs on your own tools")
                        .font(.serif(25))
                        .foregroundStyle(Color.text1)
                    Text("There's no Fathom account. It reads GitHub through the GitHub CLI and thinks with your Claude plan through Claude Code.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                CheckAgainButton()
            }
            SetupRows()
        }
        .padding(24)
        .frame(maxWidth: 640)
        .card(22)
    }
}

struct CheckAgainButton: View {
    @Environment(AppStore.self) private var store
    @State private var spinning = false

    var body: some View {
        Button {
            spinning = true
            Task {
                await store.setup.check()
                spinning = false
            }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(spinning)
    }
}

/// GitHub CLI and Claude Code, each with its state and the one thing to do next.
struct SetupRows: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let setup = store.setup
        VStack(alignment: .leading, spacing: 0) {
            github(setup)
            Rectangle().fill(Color.hair).frame(height: 0.5).padding(.vertical, 14)
            claude(setup)
        }
    }

    @ViewBuilder private func github(_ setup: Setup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch setup.github {
            case .checking:
                ToolRow(symbol: "arrow.triangle.pull", name: "GitHub CLI", status: "Checking…", tone: .checking)
            case .missing:
                ToolRow(symbol: "arrow.triangle.pull", name: "GitHub CLI", status: "Not installed", tone: .attention) {
                    Link(destination: URL(string: "https://cli.github.com")!) { Text("Other Ways") }
                        .font(.system(size: 12))
                }
                CommandChip(command: "brew install gh")
            case .signedOut:
                ToolRow(symbol: "arrow.triangle.pull", name: "GitHub CLI", status: "Installed, not signed in", tone: .attention) {
                    if setup.signIn == nil {
                        Button("Sign In to GitHub") { setup.signInToGitHub() }
                            .buttonStyle(.glassProminent)
                            .tint(Color(hex: 0x1F6F6B))
                            .controlSize(.small)
                    }
                }
            case .ready(let login):
                ToolRow(symbol: "arrow.triangle.pull", name: "GitHub CLI", status: "Signed in as @\(login)", tone: .ready)
            case .unreachable(let message):
                ToolRow(symbol: "arrow.triangle.pull", name: "GitHub CLI", status: "Couldn't reach GitHub", tone: .attention,
                        detail: message)
            }
            if let flow = setup.signIn {
                SignInPanel(flow: flow)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private func claude(_ setup: Setup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch setup.claude {
            case .checking:
                ToolRow(symbol: "sparkle", name: "Claude Code", status: "Checking…", tone: .checking)
            case .missing:
                ToolRow(symbol: "sparkle", name: "Claude Code", status: "Not installed", tone: .attention) {
                    Link(destination: URL(string: "https://code.claude.com/docs/en/setup")!) { Text("Install Guide") }
                        .font(.system(size: 12))
                }
                CommandChip(command: "curl -fsSL https://claude.ai/install.sh | bash")
            case .outdated(let version):
                ToolRow(symbol: "sparkle", name: "Claude Code",
                        status: version.isEmpty ? "Too old for Fathom" : "Version \(version) is too old for Fathom", tone: .attention) {
                    Button("Update in Terminal") { setup.updateClaude() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            case .signedOut:
                ToolRow(symbol: "sparkle", name: "Claude Code", status: "Installed, not signed in", tone: .attention,
                        detail: "Sign in once in Terminal. Fathom notices when you come back.") {
                    Button("Sign In in Terminal") { setup.signInToClaude() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            case .ready(let account):
                ToolRow(symbol: "sparkle", name: "Claude Code", status: account, tone: .ready)
            }
        }
    }
}

struct ToolRow<Actions: View>: View {
    enum Tone { case checking, attention, ready }

    let symbol: String
    let name: String
    let status: String
    let tone: Tone
    var detail: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone == .ready ? Color.sonar : Color.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.text1)
                HStack(spacing: 6) {
                    switch tone {
                    case .checking:
                        ProgressView().controlSize(.mini)
                    case .attention:
                        Circle().fill(Color.changed).frame(width: 6, height: 6)
                    case .ready:
                        Image(systemName: "checkmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.added)
                    }
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            actions
        }
    }
}

extension ToolRow where Actions == EmptyView {
    init(symbol: String, name: String, status: String, tone: Tone, detail: String? = nil) {
        self.init(symbol: symbol, name: name, status: status, tone: tone, detail: detail) { EmptyView() }
    }
}

/// A command to paste into Terminal, with a copy button.
struct CommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.mono(12))
                .foregroundStyle(Color.text1)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                withAnimation(Motion.snappy) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(Motion.snappy) { copied = false }
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(copied ? Color.added : Color.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.28)))
        .hairline(10)
        .padding(.leading, 47)
    }
}

/// The one-time code, big enough to read across the room, and the button that takes it to github.com.
struct SignInPanel: View {
    let flow: GitHubSignIn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch flow.phase {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting a code from GitHub…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.text2)
                    Spacer()
                    Button("Cancel") { flow.cancel() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            case .code(let code):
                Eyebrow("Your one-time code")
                Text(code)
                    .font(.mono(30, .semibold))
                    .tracking(3)
                    .foregroundStyle(Color.text1)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(flow.copied ? "Copy Again and Open GitHub" : "Copy Code and Open GitHub") { flow.copyAndOpen() }
                        .buttonStyle(.glassProminent)
                        .tint(Color(hex: 0x1F6F6B))
                    Button("Cancel") { flow.cancel() }
                        .buttonStyle(.glass)
                }
                .controlSize(.regular)
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(flow.copied ? "Paste the code on github.com and approve. Fathom finishes by itself."
                                     : "Then paste it on github.com and approve. Fathom finishes by itself.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.text3)
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.changed)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Close") { flow.cancel() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .hairline(14)
        .padding(.leading, 47)
    }
}

/// ⌘, — the accounts, how Claude reads, and where Fathom keeps things.
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                SetupRows()
                    .padding(.vertical, 6)
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    CheckAgainButton()
                }
            } footer: {
                Text("Fathom has no servers and no account of its own. Pull requests come through your GitHub CLI login; readings run on your Claude plan through Claude Code.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.text3)
            }
            Section("Reading") {
                Picker("Model", selection: $store.model) {
                    Text("Claude Opus (deepest)").tag("opus")
                    Text("Claude Sonnet (quicker)").tag("sonnet")
                }
                Toggle("Read new review requests in the background", isOn: $store.autoRead)
                Toggle("Play a sonar ping when a reading is done", isOn: $store.ping)
            }
            Section("On this Mac") {
                LabeledContent("Readings, caches and checkouts") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Library.root])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }
}
