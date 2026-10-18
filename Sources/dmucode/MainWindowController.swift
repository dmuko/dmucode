import AppKit
import Combine
import SwiftUI

/// The window: tmux sessions in a sidebar, the selected session's terminal on
/// the right. Each session gets its own Ghostty surface running
/// `tmux attach-session`, created on first selection and kept alive while
/// hidden so switching is instant.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let terminals: TerminalContainerController
    private var cancellables: Set<AnyCancellable> = []

    init(store: SessionStore) {
        self.store = store
        self.terminals = TerminalContainerController(tmux: store.tmux)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "dmucode"
        // The title bar shows the terminal theme's background (drawn by the
        // content underneath) instead of the system's titlebar material.
        window.titlebarAppearsTransparent = true
        window.appearance = GhosttyRuntime.shared.theme.appearance
        window.setFrameAutosaveName("DmucodeMainWindow")
        if !window.setFrameUsingName("DmucodeMainWindow") { window.center() }

        super.init(window: window)
        window.delegate = self

        let split = NSSplitViewController()
        let sidebar = NSHostingController(rootView: SidebarView(
            store: store,
            theme: GhosttyRuntime.shared.theme,
            onNew: { [weak self] in self?.newSession(nil) },
            onRename: { [weak self] in self?.rename($0) },
            onKill: { [weak self] in self?.kill($0) }))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: terminals))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 700))

        terminals.onTerminalClosed = { [weak self] in self?.store.refresh() }
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
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.terminals.retain(ids: Set(sessions.map(\.id)))
                self?.updateTitle()
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        applyWindowBackground()
    }

    /// Like Ghostty's own app: with background-opacity < 1 the window must be
    /// see-through, or the terminal's translucent background is composited
    /// over an opaque window. Blur only takes effect once the window is
    /// visible. (Ghostty also turns this off in native fullscreen; not yet.)
    private func applyWindowBackground() {
        guard let window else { return }
        let theme = GhosttyRuntime.shared.theme
        guard theme.isTranslucent else {
            window.backgroundColor = theme.background
            return
        }
        window.isOpaque = false
        // Not .clear: Ghostty uses this to match Terminal.app's look.
        window.backgroundColor = .white.withAlphaComponent(0.001)
        GhosttyRuntime.shared.setBackgroundBlur(window)
    }

    private func showSelected() {
        let emptyText = store.isRestoring ? "Restoring tmux sessions…"
            : store.sessions.isEmpty ? "No tmux sessions.\nPress ⌘N to create one."
            : "Select a session"
        terminals.show(sessionID: store.selectedID, emptyText: emptyText)
        updateTitle()
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

    private var selectedSession: TmuxSession? {
        store.sessions.first(where: { $0.id == store.selectedID })
    }

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

/// Holds one TerminalView per opened session and shows the selected one.
final class TerminalContainerController: NSViewController {
    private let tmux: Tmux
    private var views: [String: TerminalView] = [:]
    private let theme = GhosttyRuntime.shared.theme
    private let titleStrip = NSView()
    private let placeholder = NSTextField(labelWithString: "")
    private let reattachButton = NSButton(title: "Attach", target: nil, action: nil)
    private var shownID: String?

    var onTerminalClosed: (() -> Void)?
    var onReattach: (() -> Void)?

    init(tmux: Tmux) {
        self.tmux = tmux
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
        view = root
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
            view.addSubview(created)
            views[sessionID] = created
            terminal = created
        }
        hidePlaceholder()
        terminal.setVisible(true)
        view.window?.makeFirstResponder(terminal)
    }

    /// The window uses a full-size content view, so keep terminals out from
    /// under the title bar and toolbar.
    private var terminalFrame: NSRect {
        var frame = view.bounds
        frame.size.height -= view.safeAreaInsets.top
        return frame
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        for terminal in views.values { terminal.frame = terminalFrame }
        let top = view.safeAreaInsets.top
        titleStrip.frame = NSRect(x: 0, y: view.bounds.height - top, width: view.bounds.width, height: top)
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
        placeholder.stringValue = text
        placeholder.isHidden = false
        reattachButton.isHidden = !reattach
        if theme.isTranslucent { view.layer?.backgroundColor = theme.chromeBackground.cgColor }
    }

    private func hidePlaceholder() {
        placeholder.isHidden = true
        reattachButton.isHidden = true
        if theme.isTranslucent { view.layer?.backgroundColor = NSColor.clear.cgColor }
    }
}
