import AppKit

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
        session.addItem(withTitle: "New Session…", action: #selector(MainWindowController.newSession(_:)), keyEquivalent: "n")
        session.addItem(withTitle: "Rename Session…", action: #selector(MainWindowController.renameSelected(_:)), keyEquivalent: "r")
        session.addItem(withTitle: "Kill Session…", action: #selector(MainWindowController.killSelected(_:)), keyEquivalent: "")
        session.addItem(.separator())
        let next = session.addItem(withTitle: "Next Session", action: #selector(MainWindowController.selectNextSession(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let previous = session.addItem(withTitle: "Previous Session", action: #selector(MainWindowController.selectPreviousSession(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        session.addItem(.separator())
        for i in 1...9 {
            let item = session.addItem(withTitle: "Session \(i)", action: #selector(MainWindowController.selectSessionByTag(_:)), keyEquivalent: "\(i)")
            item.tag = i
        }
        main.addItem(submenu: session, title: "Session")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
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
