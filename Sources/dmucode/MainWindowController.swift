import AppKit
import Combine
import SwiftUI

/// The window: tmux sessions in a sidebar, the selected session's terminal on
/// the right. Each session gets its own Ghostty surface running
/// `tmux attach-session`, created on first selection and kept alive while
/// hidden so switching is instant.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let git = GitStatusStore()
    private let commandBar = CommandBarModel()
    private let switcher: SessionSwitcherModel
    private let chrome = ChromeTheme(GhosttyRuntime.shared.theme)
    private let terminals: TerminalContainerController
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore) {
        self.store = store
        self.switcher = SessionSwitcherModel(store: store)
        let theme = GhosttyRuntime.shared.theme
        let git = self.git, commandBar = self.commandBar, switcher = self.switcher, chrome = self.chrome
        // The real actions need self; set below.
        let tabBar = NSHostingView(rootView: Themed(chrome) { TabBarView(
            store: store, git: git, theme: $0, onSelect: { _ in }, onNew: {}, onRename: { _ in }, onClose: { _ in }) })
        let overlay = NSHostingView(rootView: Themed(chrome) {
            PaletteOverlay(commandBar: commandBar, switcher: switcher, store: store, theme: $0) })
        self.terminals = TerminalContainerController(tmux: store.tmux, tabBar: tabBar, overlay: overlay)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "dmucode"
        // The title bar shows the terminal theme's background (drawn by the
        // content underneath) instead of the system's titlebar material.
        window.titlebarAppearsTransparent = true
        window.appearance = theme.appearance
        window.setFrameAutosaveName("DmucodeMainWindow")
        if !window.setFrameUsingName("DmucodeMainWindow") { window.center() }

        super.init(window: window)
        window.delegate = self
        tabBar.rootView = Themed(chrome) { [weak self] theme in TabBarView(
            store: store,
            git: git,
            theme: theme,
            onSelect: { self?.selectWindow($0) },
            onNew: { self?.newWindow() },
            onRename: { self?.renameWindow($0) },
            onClose: { self?.closeWindow($0) }) }

        let split = NSSplitViewController()
        let sidebar = NSHostingController(rootView: Themed(chrome) { [weak self] theme in SidebarView(
            store: store,
            theme: theme,
            onNew: { self?.newSession(nil) },
            onRename: { self?.rename($0) },
            onKill: { self?.kill($0) },
            onNewGroup: { self?.newGroup(moving: $0) },
            onRenameGroup: { self?.renameGroup($0) }) })
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: terminals))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 700))

        terminals.onTerminalClosed = { [weak self] in self?.store.refresh() }
        commandBar.onRun = { [weak self] line, done in
            guard let self, let sessionID = self.store.selectedID else {
                done(.failure(TmuxError(description: "No session selected")))
                return
            }
            self.store.runCommandLine(line, in: sessionID, done: done)
        }
        commandBar.onClose = { [weak self] in self?.terminals.setOverlayVisible(false) }
        switcher.onClose = { [weak self] in self?.terminals.setOverlayVisible(false) }
        switcher.onChoose = { [weak self] session, window in
            guard let self else { return }
            self.store.selectedID = session.id
            if let window, !window.isActive { self.selectWindow(window) }
        }
        terminals.onAlert = { [weak self] sessionID, message in
            guard let self else { return }
            // Nothing to point at if the user is looking at that session.
            if sessionID == self.store.selectedID, self.isWatching { return }
            self.store.raiseAlert(sessionID: sessionID, message: message)
        }
        // Showing a session is seeing its alert.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.clearSelectedAlert() }
            .store(in: &cancellables)
        store.$alerts.combineLatest(store.$sessions)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateDockBadge() }
            .store(in: &cancellables)
        terminals.onReattach = { [weak self] in self?.showSelected() }

        // Switching sessions inside tmux (prefix s, switch-client) moves the
        // terminal to another session; make the sidebar follow it.
        store.onClientSessionChanged = { [weak self] tty, sessionID in
            guard let self, self.terminals.clientSessionChanged(tty: tty, to: sessionID) else { return }
            self.store.selectedID = sessionID
        }

        store.$isRestoring
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showSelected() }
            .store(in: &cancellables)
        store.$selectedID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.showSelected() }
            .store(in: &cancellables)
        // Git status for the directories of the selected session's tabs.
        store.$sessions.combineLatest(store.$selectedID)
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions, selectedID in
                let windows = sessions.first(where: { $0.id == selectedID })?.windows ?? []
                self?.git.track(Set(windows.map(\.path).filter { !$0.isEmpty }))
            }
            .store(in: &cancellables)
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.terminals.retain(ids: Set(sessions.map(\.id)))
                self?.updateTitle()
            }
            .store(in: &cancellables)
        // A reloaded Ghostty config: the terminals update themselves, the
        // chrome here (see updateChrome).
        GhosttyRuntime.shared.$theme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateChrome() }
            .store(in: &cancellables)
        GhosttyRuntime.shared.$configErrors
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.showConfigErrors($0) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyWindowBackground(chrome.theme)
        showConfigErrors(GhosttyRuntime.shared.configErrors)
    }

    /// Like Ghostty's own app: with background-opacity < 1 the window must be
    /// see-through, or the terminal's translucent background is composited
    /// over an opaque window. Blur only takes effect once the window is
    /// visible.
    private func applyWindowBackground(_ theme: TerminalTheme) {
        guard let window else { return }
        guard theme.isTranslucent else {
            window.isOpaque = true
            window.backgroundColor = theme.background
            return
        }
        window.isOpaque = false
        // Not .clear: Ghostty uses this to match Terminal.app's look.
        window.backgroundColor = .white.withAlphaComponent(0.001)
        GhosttyRuntime.shared.setBackgroundBlur(window)
    }

    /// Applies the config's theme to the chrome, opaque in native fullscreen
    /// as in Ghostty: behind the window there is only the Space's gray
    /// background, which the sidebar's material and any translucency would
    /// show. The terminals stay as configured, now on an opaque backdrop of
    /// the same color, so they look opaque too.
    private func updateChrome() {
        let config = GhosttyRuntime.shared.theme
        let theme = window?.styleMask.contains(.fullScreen) == true ? config.opaque : config
        if chrome.theme != theme { chrome.theme = theme }
        window?.appearance = theme.appearance
        applyWindowBackground(theme)
        terminals.applyTheme(theme)
    }

    // MARK: Ghostty config

    @objc func reloadGhosttyConfig(_ sender: Any?) {
        GhosttyRuntime.shared.reloadConfig()
    }

    /// The errors last shown, so saving the same broken config again (or
    /// reloading) doesn't repeat the sheet.
    private var shownConfigErrors: [String] = []

    /// libghostty skips bad lines and applies the rest, like Ghostty; this
    /// says which were skipped.
    private func showConfigErrors(_ errors: [String]) {
        guard !errors.isEmpty else {
            shownConfigErrors = []
            return
        }
        guard errors != shownConfigErrors, let window, window.isVisible, window.attachedSheet == nil else { return }
        shownConfigErrors = errors
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The Ghostty config has errors"
        alert.informativeText = errors.prefix(10).joined(separator: "\n")
            + (errors.count > 10 ? "\n…" : "")
            + "\n\nThose lines were skipped; the rest of the config is in effect."
        alert.beginSheetModal(for: window)
    }

    var themeState: String {
        let theme = GhosttyRuntime.shared.theme
        func hex(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)),
                          Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        }
        let effects = (window?.contentView?.superview ?? window?.contentView).map(Self.effectViews) ?? []
        return "theme=\(hex(theme.background))/\(hex(theme.foreground)) opacity=\(theme.opacity) chrome-opacity=\(chrome.theme.opacity)"
            + " window: opaque=\(window?.isOpaque ?? false) bg=\(window?.backgroundColor.map(hex) ?? "-")"
            + " fullscreen=\(window?.styleMask.contains(.fullScreen) ?? false)"
            + " effectViews=[\(effects.joined(separator: ","))]"
            + " appearance=\(window?.appearance?.name.rawValue ?? "-")"
            + " errors=\(GhosttyRuntime.shared.configErrors.count) sheet=\(window?.attachedSheet != nil)"
    }

    private static func effectViews(in view: NSView) -> [String] {
        var found: [String] = []
        if let effect = view as? NSVisualEffectView {
            found.append("\(effect.material.rawValue)/\(effect.blendingMode == .behindWindow ? "behind" : "within")/\(effect.state.rawValue)")
        }
        return found + view.subviews.flatMap(effectViews)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { updateChrome() }

    func windowDidBecomeKey(_ notification: Notification) {
        clearSelectedAlert()
    }

    /// The window is in front of the user, so the shown session is seen.
    private var isWatching: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.isMiniaturized == false
    }

    private func clearSelectedAlert() {
        guard let id = store.selectedID, isWatching else { return }
        store.clearAlert(sessionID: id)
    }

    /// The number of sessions that want attention, on the Dock icon.
    private func updateDockBadge() {
        let count = store.sessions.filter { store.needsAttention($0) }.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func showSelected() {
        let emptyText = store.isRestoring ? "Restoring tmux sessions…"
            : store.sessions.isEmpty ? "No tmux sessions.\nPress ⌘N to create one."
            : "Select a session"
        terminals.show(sessionID: store.selectedID, emptyText: emptyText)
        updateTitle()
        clearSelectedAlert()
    }

    private func updateTitle() {
        let name = store.sessions.first(where: { $0.id == store.selectedID })?.name
        window?.title = name ?? "dmucode"
    }

    // MARK: Actions (also reachable from the menu via the responder chain)

    @objc func newSession(_ sender: Any?) {
        guard let name = prompt(title: "New tmux session", message: "Name (leave empty for tmux's default):", value: "") else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var newID: String?
        store.perform({ tmux in
            newID = try tmux.newSession(name: name, directory: home)
        }, then: { [weak self] in
            if let newID { self?.store.selectedID = newID }
        })
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let session = selectedSession else { return }
        rename(session)
    }

    @objc func killSelected(_ sender: Any?) {
        guard let session = selectedSession else { return }
        kill(session)
    }

    @objc func selectSessionByTag(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        guard store.sessions.indices.contains(index) else { return }
        store.selectedID = store.sessions[index].id
    }

    @objc func selectNextSession(_ sender: Any?) { step(1) }
    @objc func selectPreviousSession(_ sender: Any?) { step(-1) }

    private var selectedSession: TmuxSession? { store.selectedSession }

    private func step(_ delta: Int) {
        let sessions = store.sessions
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex(where: { $0.id == store.selectedID }) ?? 0
        let next = (current + delta + sessions.count) % sessions.count
        store.selectedID = sessions[next].id
    }

    private func rename(_ session: TmuxSession) {
        guard let name = prompt(title: "Rename session", message: "New name for “\(session.name)”:", value: session.name),
              !name.isEmpty, name != session.name else { return }
        store.perform { tmux in try tmux.renameSession(id: session.id, to: name) }
    }

    private func newGroup(moving session: TmuxSession?) {
        guard let name = prompt(title: "New group", message: "Name for the group:", value: ""),
              !name.isEmpty else { return }
        if !store.addGroup(name, moving: session?.id) { NSSound.beep() }
    }

    private func renameGroup(_ group: String) {
        guard let name = prompt(title: "Rename group", message: "New name for “\(group)”:", value: group),
              !name.isEmpty, name != group else { return }
        if !store.renameGroup(group, to: name) { NSSound.beep() }
    }

    private func kill(_ session: TmuxSession) {
        let alert = NSAlert()
        alert.messageText = "Kill tmux session “\(session.name)”?"
        alert.informativeText = "All of its windows and the programs running in them will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.perform { tmux in try tmux.killSession(id: session.id) }
    }

    // MARK: Command bar

    @objc func toggleCommandBar(_ sender: Any?) {
        if commandBar.isOpen {
            commandBar.close()
            return
        }
        guard store.selectedID != nil else { NSSound.beep(); return }
        if commandBar.commands.isEmpty {
            store.listCommands { [weak self] in self?.commandBar.commands = $0 }
        }
        switcher.close()
        commandBar.open()
        terminals.setOverlayVisible(true)
    }

    // MARK: Session switcher

    @objc func toggleSwitcher(_ sender: Any?) {
        if switcher.isOpen {
            switcher.close()
            return
        }
        guard !store.sessions.isEmpty else { NSSound.beep(); return }
        commandBar.close()
        switcher.open()
        terminals.setOverlayVisible(true)
    }

    var switcherState: String { switcher.debugState }

    /// Runs a line through the command bar (debug hook).
    func runInCommandBar(_ line: String) {
        if !commandBar.isOpen { toggleCommandBar(nil) }
        commandBar.text = line
        commandBar.submit()
    }

    var commandBarState: String {
        let outcome: String
        switch commandBar.outcome {
        case .output(let text)?: outcome = "output=" + text.replacingOccurrences(of: "\n", with: " | ")
        case .error(let text)?: outcome = "error=" + text
        case nil: outcome = "-"
        }
        return "cmdbar open=\(commandBar.isOpen) \(outcome)"
    }

    // MARK: Windows (tabs)

    // Menu actions: they act on the selected session's current window.

    @objc func newTab(_ sender: Any?) { newWindow() }

    @objc func closeTab(_ sender: Any?) {
        guard let current = currentWindow else { return }
        closeWindow(current)
    }

    @objc func renameTab(_ sender: Any?) {
        guard let current = currentWindow else { return }
        renameWindow(current)
    }

    // Not selectNextTab/selectPreviousTab: NSWindow has those for native
    // window tabs, comes first in the responder chain and disables them.
    @objc func selectNextTmuxWindow(_ sender: Any?) { stepWindow(1) }
    @objc func selectPreviousTmuxWindow(_ sender: Any?) { stepWindow(-1) }

    /// ⌥⌘1…9: the Nth tab from the left, whatever tmux's base-index.
    @objc func selectTabByTag(_ sender: NSMenuItem) {
        guard let windows = selectedSession?.windows, windows.indices.contains(sender.tag - 1) else { return }
        selectWindow(windows[sender.tag - 1])
    }

    private var currentWindow: TmuxWindow? {
        selectedSession?.windows.first(where: \.isActive)
    }

    private func stepWindow(_ delta: Int) {
        guard let windows = selectedSession?.windows, !windows.isEmpty else { return }
        let current = windows.firstIndex(where: \.isActive) ?? 0
        selectWindow(windows[(current + delta + windows.count) % windows.count])
    }

    private func selectWindow(_ tmuxWindow: TmuxWindow) {
        guard let sessionID = store.selectedID else { return }
        store.selectWindow(tmuxWindow.id, in: sessionID)
        terminals.focusShown()
    }

    private func newWindow() {
        guard let sessionID = store.selectedID else { return }
        store.perform { tmux in try tmux.newWindow(sessionID: sessionID) }
        terminals.focusShown()
    }

    private func renameWindow(_ tmuxWindow: TmuxWindow) {
        guard let sessionID = store.selectedID,
              let name = prompt(title: "Rename window", message: "New name for “\(tmuxWindow.name)”:", value: tmuxWindow.name),
              !name.isEmpty, name != tmuxWindow.name else { return }
        store.perform { tmux in try tmux.renameWindow(sessionID: sessionID, windowID: tmuxWindow.id, to: name) }
    }

    private func closeWindow(_ tmuxWindow: TmuxWindow) {
        guard let sessionID = store.selectedID else { return }
        let alert = NSAlert()
        alert.messageText = "Close tmux window “\(tmuxWindow.name)”?"
        alert.informativeText = "Its panes and the programs running in them will be terminated."
            + (selectedSession?.windows.count == 1 ? " It is the session's last window, so the session ends too." : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.perform { tmux in try tmux.killWindow(sessionID: sessionID, windowID: tmuxWindow.id) }
    }

    private func prompt(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds one TerminalView per opened session and shows the selected one,
/// with the session's windows as tabs above it.
final class TerminalContainerController: NSViewController {
    private let tmux: Tmux
    private let tabBar: NSView
    /// The command bar or the switcher (PaletteOverlay).
    private let overlay: NSView
    private var views: [String: TerminalView] = [:]
    private var theme = GhosttyRuntime.shared.theme
    private let titleStrip = NSView()
    private let placeholder = NSTextField(labelWithString: "")
    private let reattachButton = NSButton(title: "Attach", target: nil, action: nil)
    private var shownID: String?

    var onTerminalClosed: (() -> Void)?
    var onReattach: (() -> Void)?
    /// A terminal rang the bell (nil) or posted a notification (its text).
    var onAlert: ((_ sessionID: String, _ message: String?) -> Void)?

    init(tmux: Tmux, tabBar: NSView, overlay: NSView) {
        self.tmux = tmux
        self.tabBar = tabBar
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        // Under the terminals. With translucent terminals it must stay clear,
        // or it would add to their background; it gets the theme color only
        // while no terminal is shown (see showPlaceholder).
        root.layer?.backgroundColor = theme.isTranslucent ? NSColor.clear.cgColor : theme.background.cgColor

        // The strip under the transparent title bar, above the terminals.
        titleStrip.wantsLayer = true
        titleStrip.layer?.backgroundColor = theme.chromeBackground.cgColor
        root.addSubview(titleStrip)
        tabBar.isHidden = true
        root.addSubview(tabBar)

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        reattachButton.target = self
        reattachButton.action = #selector(reattach)
        let stack = NSStackView(views: [placeholder, reattachButton])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        // Floats over the terminal below the tab bar, sized to its content
        // so it doesn't block clicks elsewhere.
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlay.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: TabBarView.height + 8),
        ])
        view = root
    }

    func setOverlayVisible(_ visible: Bool) {
        overlay.isHidden = !visible
        if visible {
            // Above the terminals, which are added later.
            view.addSubview(overlay, positioned: .above, relativeTo: nil)
            view.window?.makeFirstResponder(overlay)
        } else {
            // Next turn of the run loop: hiding the bar drops focus to the
            // window, and SwiftUI updates the field's focus after this.
            // Not if the other panel opened meanwhile (⌘: while ⌘K is open).
            DispatchQueue.main.async { [weak self] in
                if self?.overlay.isHidden == true { self?.focusShown() }
            }
        }
    }

    func show(sessionID: String?, emptyText: String) {
        shownID = sessionID
        for (id, view) in views where id != sessionID { view.setVisible(false) }

        guard let sessionID else {
            showPlaceholder(emptyText, reattach: false)
            return
        }

        let terminal: TerminalView
        if let existing = views[sessionID] {
            terminal = existing
        } else {
            guard let app = GhosttyRuntime.shared.app,
                  let created = TerminalView(app: app, command: tmux.attachCommand(sessionID: sessionID)) else {
                showPlaceholder("Could not create a terminal surface.", reattach: false)
                return
            }
            created.frame = terminalFrame
            created.onClose = { [weak self, weak created] in
                if let created { self?.terminalClosed(created) }
            }
            created.onAlert = { [weak self, weak created] message in
                // Looked up now: the terminal may have moved to another session.
                guard let self, let id = self.views.first(where: { $0.value === created })?.key else { return }
                self.onAlert?(id, message)
            }
            view.addSubview(created)
            views[sessionID] = created
            terminal = created
        }
        hidePlaceholder()
        terminal.setVisible(true)
        view.window?.makeFirstResponder(terminal)
    }

    /// The window uses a full-size content view, so keep terminals out from
    /// under the title bar and toolbar, and below the tab bar.
    private var terminalFrame: NSRect {
        var frame = view.bounds
        frame.size.height -= view.safeAreaInsets.top + TabBarView.height
        return frame
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        for terminal in views.values { terminal.frame = terminalFrame }
        let top = view.safeAreaInsets.top
        titleStrip.frame = NSRect(x: 0, y: view.bounds.height - top, width: view.bounds.width, height: top)
        tabBar.frame = NSRect(x: 0, y: view.bounds.height - top - TabBarView.height,
                              width: view.bounds.width, height: TabBarView.height)
    }

    /// Gives the keyboard back to the visible terminal, e.g. after a tab click.
    func focusShown() {
        guard let shownID, let terminal = views[shownID] else { return }
        view.window?.makeFirstResponder(terminal)
    }

    /// Drops terminals whose session no longer exists.
    func retain(ids: Set<String>) {
        for (id, terminal) in views where !ids.contains(id) {
            terminal.removeFromSuperview()
            views[id] = nil
        }
    }

    /// A tmux client switched sessions. If it belongs to one of our
    /// terminals, re-key that terminal under the new session (one terminal
    /// per session). Returns true if it was the visible terminal.
    func clientSessionChanged(tty: String, to newID: String) -> Bool {
        guard let (oldID, terminal) = views.first(where: { $0.value.ttyName == tty }),
              oldID != newID else { return false }
        views[oldID] = nil
        if let duplicate = views[newID] {
            // Freeing its surface detaches that tmux client.
            duplicate.removeFromSuperview()
        }
        views[newID] = terminal
        guard oldID == shownID else { return false }
        shownID = newID
        return true
    }

    /// The tmux client exited: the session was killed or ended, or the user
    /// detached (prefix d). Offer to re-attach; the store refresh removes the
    /// row if the session is gone.
    private func terminalClosed(_ terminal: TerminalView) {
        terminal.removeFromSuperview()
        guard let id = views.first(where: { $0.value === terminal })?.key else { return }
        views[id] = nil
        if id == shownID {
            showPlaceholder("Detached from this session.", reattach: true)
        }
        onTerminalClosed?()
    }

    @objc private func reattach() {
        onReattach?()
    }

    private func showPlaceholder(_ text: String, reattach: Bool) {
        tabBar.isHidden = true
        placeholder.stringValue = text
        placeholder.isHidden = false
        reattachButton.isHidden = !reattach
        updateBackground()
    }

    private func hidePlaceholder() {
        tabBar.isHidden = false
        placeholder.isHidden = true
        reattachButton.isHidden = true
        updateBackground()
    }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        titleStrip.layer?.backgroundColor = theme.chromeBackground.cgColor
        updateBackground()
    }

    /// Under the terminals: clear with translucent terminals, or it would
    /// add to their background, except while no terminal is shown.
    private func updateBackground() {
        let color = !theme.isTranslucent ? theme.background
            : placeholder.isHidden ? .clear : theme.chromeBackground
        view.layer?.backgroundColor = color.cgColor
    }
}

/// The theme the window chrome is drawn with: the Ghostty config's, made
/// opaque in native fullscreen (MainWindowController.updateChrome).
final class ChromeTheme: ObservableObject {
    @Published var theme: TerminalTheme

    init(_ theme: TerminalTheme) {
        self.theme = theme
    }
}

/// Renders its content with the chrome's theme, again whenever it changes
/// (a reloaded Ghostty config, entering or leaving fullscreen).
struct Themed<Content: View>: View {
    @ObservedObject private var chrome: ChromeTheme
    private let content: (TerminalTheme) -> Content

    init(_ chrome: ChromeTheme, @ViewBuilder _ content: @escaping (TerminalTheme) -> Content) {
        self.chrome = chrome
        self.content = content
    }

    var body: some View { content(chrome.theme) }
}
