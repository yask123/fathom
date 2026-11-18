// Tracer: watch what a pull request does before you read it.
// A native SwiftUI app over `gh` (GitHub) and `claude -p` (Claude Code on your own subscription).
// (It was called Fathom; the folder, the bundle id and the FATHOM_ switches keep that name.)

import AppKit
import SwiftUI

@main
struct TracerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // In the usual run this is just the store. Asked for a picture (FATHOM_RENDER), it draws one off screen and quits
    // before any window is made.
    @State private var store = Render.boot()

    var body: some Scene {
        Window(Brand.name, id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 1180, minHeight: 740)
                .preferredColorScheme(store.appearance.scheme)
                .onOpenURL { url in
                    if let ref = PRRef.parse(url.absoluteString) { store.open(ref) }
                }
                .onAppear {
                    delegate.store = store
                    store.appearance.apply()
                    // FATHOM_QUIET=1 is for checks while the Mac is in use: the window takes no clicks and no keys,
                    // stays out of the Dock and the app switcher, and sits in a corner with only a sliver showing.
                    if store.env["FATHOM_QUIET"] == "1" {
                        NSApp.setActivationPolicy(.accessory)
                        for delay in [0.0, 0.4, 1.6, 3.1] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                guard let w = NSApp.windows.first(where: { $0.contentView != nil }), let screen = w.screen ?? NSScreen.main else { return }
                                w.ignoresMouseEvents = true
                                w.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 56, y: screen.visibleFrame.minY + 56 - w.frame.height))
                                w.orderFrontRegardless()
                            }
                        }
                    }
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
        .commands { TracerCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(store.appearance.scheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // gh, git and claude read our stdin; if one exits first, a write must fail quietly, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A GitHub sign-in still waiting for its code would otherwise keep polling GitHub after the app quits.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.setup.signIn?.cancel() }
    }

    /// Back from Terminal or a browser after installing or signing in: look again.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            guard let setup = store?.setup, setup.needsAttention, setup.signIn == nil else { return }
            await setup.check()
        }
    }
}

struct TracerCommands: Commands {
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
            Button("Toggle Sidebar") {
                withAnimation(Motion.spring) {
                    store.focus = false
                    store.sidebarShown.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(store.focus ? "Leave Focus" : "Focus") { store.toggleFocus() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.session == nil)
        }
        CommandMenu("Pull Request") {
            Button("Trace") { withAnimation(Motion.spring) { store.session?.tab = .brief } }
                .keyboardShortcut("1")
            Button("Code") { withAnimation(Motion.spring) { store.session?.tab = .changes } }
                .keyboardShortcut("2")
            Divider()
            Button("Ask Claude…") {
                withAnimation(Motion.spring) { store.session?.askOpen = true }
                store.session?.askFocusTick += 1
            }
            .keyboardShortcut("k")
            // ⌘↩ adds the comment being written, if there is one; otherwise it opens the review.
            Button("Review…") { store.session?.commandReturn() }
            .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Trace Again") { store.session?.sound() }
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
