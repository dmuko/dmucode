import AppKit
import dmucodeCore

// If started from inside tmux, `tmux attach` would refuse to nest.
unsetenv("TMUX")
unsetenv("TMUX_PANE")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        guard let tmux = Tmux.resolve() else {
            fail("tmux not found", "Install tmux (e.g. brew install tmux) or set DMUCODE_TMUX to its path.")
            return
        }
        guard GhosttyRuntime.shared.start() else {
            fail("libghostty failed to start", "See Console.app for details.")
            return
        }

        let store = SessionStore(tmux: tmux)
        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        if let window = controller.window { DebugHooks.install(window: window, store: store) }
        NSApp.activate(ignoringOtherApps: true)
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Opts in to secure coding for restorable state; macOS 14 warns otherwise.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyRuntime.shared.setFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyRuntime.shared.setFocus(false)
    }

    private func fail(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        // ⌘⇧, like Ghostty; saving a config file reloads it too.
        app.addItem(withTitle: "Reload Ghostty Config", action: #selector(MainWindowController.reloadGhosttyConfig(_:)), keyEquivalent: ",")
            .keyEquivalentModifierMask = [.command, .shift]
        app.addItem(.separator())
        app.addItem(withTitle: "Hide dmucode", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        // Quitting only detaches: the tmux sessions keep running.
        app.addItem(withTitle: "Quit dmucode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "dmucode")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let session = NSMenu(title: "Session")
        // ⌘: (⌘⇧. on US and Finnish layouts), like tmux's prefix :.
        session.addItem(withTitle: "tmux Command…", action: #selector(MainWindowController.toggleCommandBar(_:)), keyEquivalent: ":")
        // Takes ⌘K from Ghostty's clear_screen; in tmux, `clear` or C-l does that.
        session.addItem(withTitle: "Switch to Session…", action: #selector(MainWindowController.toggleSwitcher(_:)), keyEquivalent: "k")
        session.addItem(.separator())
        session.addItem(withTitle: "New Session…", action: #selector(MainWindowController.newSession(_:)), keyEquivalent: "n")
        session.addItem(withTitle: "Rename Session…", action: #selector(MainWindowController.renameSelected(_:)), keyEquivalent: "r")
        session.addItem(withTitle: "Kill Session…", action: #selector(MainWindowController.killSelected(_:)), keyEquivalent: "")
        session.addItem(.separator())
        // ⌘↑/⌘↓ for sessions (the sidebar is vertical), ⌘←/⌘→ for tabs.
        // These take the keys from Ghostty's own cmd+arrow bindings.
        session.addItem(withTitle: "Previous Session", action: #selector(MainWindowController.selectPreviousSession(_:)),
                        keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        session.addItem(withTitle: "Next Session", action: #selector(MainWindowController.selectNextSession(_:)),
                        keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        session.addItem(.separator())
        for i in 1...9 {
            let item = session.addItem(withTitle: "Session \(i)", action: #selector(MainWindowController.selectSessionByTag(_:)), keyEquivalent: "\(i)")
            item.tag = i
        }
        main.addItem(submenu: session, title: "Session")

        // Tabs are the selected session's tmux windows. ⌥⌘ for the rest keeps
        // them apart from the session shortcuts.
        let tab = NSMenu(title: "Tab")
        tab.addItem(withTitle: "New Tab", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "t")
        tab.addItem(withTitle: "Rename Tab…", action: #selector(MainWindowController.renameTab(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        tab.addItem(withTitle: "Close Tab…", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        tab.addItem(.separator())
        tab.addItem(withTitle: "Previous Tab", action: #selector(MainWindowController.selectPreviousTmuxWindow(_:)),
                    keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        tab.addItem(withTitle: "Next Tab", action: #selector(MainWindowController.selectNextTmuxWindow(_:)),
                    keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        tab.addItem(.separator())
        for i in 1...9 {
            let item = tab.addItem(withTitle: "Tab \(i)", action: #selector(MainWindowController.selectTabByTag(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = i
        }
        main.addItem(submenu: tab, title: "Tab")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        // ⌃⌘F, the system's and Ghostty's; AppKit retitles it to Exit Full Screen.
        window.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        window.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
