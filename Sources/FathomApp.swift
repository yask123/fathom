// Fathom: understand a pull request before you read it.
// A native SwiftUI app over `gh` (GitHub) and `claude -p` (Claude Code on your own subscription).

import AppKit
import SwiftUI

@main
struct FathomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("Fathom", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1180, minHeight: 740)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if let ref = PRRef.parse(url.absoluteString) { store.open(ref) }
                }
                .onAppear {
                    delegate.store = store
                    // FATHOM_WINDOW=1188x884 sizes the window for screenshots.
                    if let spec = store.env["FATHOM_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), spec.count == 2 {
                        for delay in [0.3, 1.5, 3.0] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                NSApp.windows.first?.setContentSize(NSSize(width: spec[0], height: spec[1]))
                            }
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1520, height: 950)
        .windowResizability(.contentMinSize)
        .commands { FathomCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // gh, git and claude read our stdin; if one exits first, a write must fail quietly, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Back from Terminal or a browser after installing or signing in: look again.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            guard let setup = store?.setup, setup.needsAttention, setup.signIn == nil else { return }
            await setup.check()
        }
    }
}

struct FathomCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Pull Request…") {
                withAnimation(Motion.spring) { store.sidebarShown = true }
                store.linkFocusTick += 1
            }
            .keyboardShortcut("l")
            Button("Refresh Inbox") { Task { await store.refreshInbox() } }
                .keyboardShortcut("r")
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { withAnimation(Motion.spring) { store.sidebarShown.toggle() } }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandMenu("Pull Request") {
            Button("Map") { withAnimation(Motion.spring) { store.session?.tab = .brief } }
                .keyboardShortcut("1")
            Button("Changes") { withAnimation(Motion.spring) { store.session?.tab = .changes } }
                .keyboardShortcut("2")
            Divider()
            Button("Ask Claude…") {
                withAnimation(Motion.spring) { store.session?.askOpen = true }
                store.session?.askFocusTick += 1
            }
            .keyboardShortcut("k")
            Button("Review…") { store.session?.reviewOpen = true }
                .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Read Again") { store.session?.sound() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open on GitHub") {
                if let ref = store.session?.ref { NSWorkspace.shared.open(ref.web) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Close Pull Request") { store.close() }
                .keyboardShortcut(.escape, modifiers: .command)
        }
    }
}
