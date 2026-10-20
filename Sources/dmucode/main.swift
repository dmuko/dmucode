import AppKit
import dmucodeCore

// If started from inside tmux, `tmux attach` would refuse to nest.
unsetenv("TMUX")
unsetenv("TMUX_PANE")

// Writing to a tmux process that has exited (e.g. the control client's
// stdin) would otherwise raise SIGPIPE and kill the app; ignored, the write
// fails with EPIPE, which the callers handle.
signal(SIGPIPE, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var menu: AppMenu?
    private var config = AppConfig()
    private var configWatcher: ConfigWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = AppMenu()
        self.menu = menu
        NSApp.mainMenu = menu.menu
        loadConfig()

        if let tmux = Tmux.resolve() {
            launch(tmux)
        } else {
            // Not in the usual places: ask the login shell, off the main thread.
            Tmux.resolveViaLoginShell { [weak self] tmux in
                if let tmux {
                    self?.launch(tmux)
                } else {
                    self?.fail("tmux not found", """
                        Looked in the Homebrew, MacPorts and Nix locations and in your login shell's PATH. \
                        Install tmux (e.g. brew install tmux), or set DMUCODE_TMUX to its path.
                        """)
                }
            }
        }
    }

    private func launch(_ tmux: Tmux) {
        guard GhosttyRuntime.shared.start() else {
            fail("libghostty failed to start", "See Console.app for details.")
            return
        }

        // sesh's session templates in the palette, if sesh is installed.
        let store = SessionStore(tmux: tmux, templates: Sesh.resolve(tmux: tmux))
        let controller = MainWindowController(store: store)
        controller.reloadAppConfig = { [weak self] in self?.loadConfig() }
        windowController = controller
        controller.showWindow(nil)
        controller.showConfigErrors(config.errors, of: .dmucode)
        if let window = controller.window { DebugHooks.install(window: window, store: store) }
        NSApp.activate(ignoringOtherApps: true)
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: dmucode config

    /// Reads ~/.config/dmucode/config (see `AppConfig`) and applies its
    /// shortcuts. Called at launch, by Reload Config, and when the file is
    /// saved; the watcher starts once the directory exists.
    private func loadConfig() {
        let path = AppConfig.path()
        config = AppConfig.load(path: path)
        for error in config.errors { Log.config.error("\(path, privacy: .public): \(error, privacy: .public)") }
        menu?.apply(config.keybindings)
        windowController?.showConfigErrors(config.errors, of: .dmucode)
        if configWatcher == nil {
            configWatcher = ConfigWatcher(directories: [AppConfig.directory()], files: ["config"], subdirectories: []) { [weak self] in
                self?.loadConfig()
            }
        }
    }

    var menuDebugState: String { menu?.debugState ?? "" }

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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
