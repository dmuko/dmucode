import Foundation

/// The sidebar's model: the tmux server's sessions.
///
/// Updates are event-driven through a tmux control-mode connection: a
/// notification such as %sessions-changed triggers a re-query over the same
/// connection. A control client has to attach to some session, so while the
/// server has none (or isn't running) the store polls the CLI once a second
/// and connects as soon as a session appears. All state is touched on the
/// main thread.
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [TmuxSession] = []

    public var selectedSession: TmuxSession? { sessions.first { $0.id == selectedID } }
    @Published public var selectedID: String? {
        didSet {
            if let id = selectedID, recentIDs.first != id {
                recentIDs.removeAll { $0 == id }
                recentIDs.insert(id, at: 0)
            }
            guard !selectingAutomatically else { return }
            // A choice by the user (sidebar, shortcut, switching inside tmux)
            // is the session to come back to next time.
            selectionIsAutomatic = false
            if let name = sessions.first(where: { $0.id == selectedID })?.name {
                defaults.set(name, forKey: lastSessionKey)
            }
        }
    }
    /// Sessions in the order they were shown, most recent first (for ⌘K).
    public private(set) var recentIDs: [String] = []
    /// The sidebar's order and groups; `sessions` follows it.
    @Published public private(set) var layout = SidebarLayout()
    public var sidebarRows: [SidebarLayout.Row] { layout.rows(for: sessions) }
    /// The error shown under the sidebar. Kept apart by source, so a
    /// successful refresh doesn't wipe a command's error a moment later.
    public var errorMessage: String? { commandError ?? connectionError ?? listError }
    /// A tmux command failed (e.g. renaming to a taken name). Stays until
    /// the next command succeeds or the user dismisses it.
    @Published public private(set) var commandError: String?
    /// The control-mode client couldn't start. Stays until it connects.
    @Published private(set) var connectionError: String?
    /// Listing the sessions failed. Cleared by the next successful listing.
    @Published private(set) var listError: String?
    /// True while updates arrive as control-mode events, false while polling.
    @Published public private(set) var isLive = false
    /// True while tmux-continuum restores sessions after we started the server.
    @Published public private(set) var isRestoring = false
    /// Sessions that want attention according to our own terminals: a bell,
    /// or a desktop notification such as Claude Code waiting for input
    /// (its text, if any). tmux's own bell flags are on the windows.
    @Published public private(set) var alerts: [String: TerminalAlert] = [:]
    /// Sessions with terminal output in the last few seconds (from the
    /// activity subscription), for example an agent at work. See `isWorking`.
    @Published public private(set) var working: Set<String> = []

    /// A tmux client moved to another session (prefix s, switch-client...):
    /// the client's tty and the new session id.
    public var onClientSessionChanged: ((_ tty: String, _ sessionID: String) -> Void)?

    /// What the app may ask of tmux (see `perform`).
    public var tmux: any TmuxCommands { backend }
    private let backend: any TmuxBackend
    /// Session templates (sesh), if a source is installed.
    private let templates: (any SessionTemplates)?
    public var hasTemplates: Bool { templates != nil }
    private let makeControl: (_ sessionID: String) throws -> any TmuxControlConnection
    private let scheduler: StoreScheduler
    private let defaults: UserDefaults
    private var control: (any TmuxControlConnection)?
    private var stopPolling: (() -> Void)?
    private var cliRefreshing = false
    private var refreshScheduled = false
    /// The throwaway session that started the server for a restore. Hidden
    /// until tmux-resurrect kills it, which marks the restore as done.
    private var restorePlaceholderID: String?

    /// The current selection was made by fixSelection, not the user, so the
    /// remembered session may replace it once it appears (e.g. restored).
    private var selectionIsAutomatic = true
    private var selectingAutomatically = false

    /// Remembered by name: ids change when the tmux server restarts (e.g.
    /// after tmux-resurrect), names survive. Kept per tmux socket.
    private var lastSessionKey: String {
        "lastSessionName" + (backend.socketName.map { "-" + $0 } ?? "")
    }
    private var layoutKey: String {
        "sidebarLayout" + (backend.socketName.map { "-" + $0 } ?? "")
    }

    /// Notifications after which the session list (names, windows, current
    /// window, paths, attached clients) may have changed. Windows of the control
    /// client's own session come as %window-*, others as %unlinked-window-*.
    private static let listEvents: Set<String> = [
        "%sessions-changed", "%session-renamed", "%session-changed",
        "%client-session-changed", "%client-detached", "%session-window-changed",
        "%window-add", "%window-close", "%window-renamed",
        "%unlinked-window-add", "%unlinked-window-close", "%unlinked-window-renamed",
        "%subscription-changed",
    ]

    public convenience init(tmux: Tmux, templates: (any SessionTemplates)? = nil) {
        self.init(backend: tmux,
                  templates: templates,
                  makeControl: { try TmuxControlClient(tmux: tmux, sessionID: $0) },
                  scheduler: DispatchScheduler(),
                  defaults: .standard)
    }

    init(backend: any TmuxBackend,
         templates: (any SessionTemplates)? = nil,
         makeControl: @escaping (_ sessionID: String) throws -> any TmuxControlConnection,
         scheduler: StoreScheduler,
         defaults: UserDefaults) {
        self.backend = backend
        self.templates = templates
        self.makeControl = makeControl
        self.scheduler = scheduler
        self.defaults = defaults
        let loaded = SidebarLayout.load(from: defaults.data(forKey: layoutKey))
        layout = loaded.layout
        layoutMayOverwrite = loaded.mayOverwrite
    }

    /// False while the stored layout is in a newer format than we know: it
    /// is left alone, and this run's layout isn't saved.
    private var layoutMayOverwrite = true

    public func start() {
        startPolling()
        let tmux = backend
        scheduler.background {
            // After a reboot there is no tmux server. If tmux-resurrect has a
            // save, start the server so tmux-continuum restores it.
            var placeholder: String?
            if tmux.hasResurrectSave, (try? tmux.isServerRunning()) == false {
                placeholder = try? tmux.startServerForRestore()
            }
            self.scheduler.main {
                if let placeholder { self.beginRestore(placeholder: placeholder) }
                self.refresh()
            }
        }
    }

    private func beginRestore(placeholder: String) {
        restorePlaceholderID = placeholder
        isRestoring = true
        // If nothing restores (continuum missing, another tmux server
        // running...), give up and show the session like any other.
        scheduler.after(20) { [weak self] in
            guard let self, self.restorePlaceholderID == placeholder else { return }
            self.endRestore()
            self.refresh()
        }
    }

    private func endRestore() {
        restorePlaceholderID = nil
        isRestoring = false
    }

    public func refresh(then completion: (() -> Void)? = nil) {
        if let control {
            control.listSessions { [weak self] result in
                // A reply failing because the connection just dropped isn't
                // worth showing; onExit falls back to polling.
                if let self, self.control === control || (try? result.get()) != nil {
                    self.apply(result.mapError { $0 as Error })
                }
                completion?()
            }
            return
        }

        guard !cliRefreshing else {
            // Retry shortly so a completion is never dropped.
            if let completion {
                scheduler.after(0.1) { self.refresh(then: completion) }
            }
            return
        }
        cliRefreshing = true
        let tmux = backend
        scheduler.background {
            let result = Result { try tmux.listSessions() }
            self.scheduler.main {
                self.cliRefreshing = false
                self.apply(result)
                self.connectIfPossible()
                completion?()
            }
        }
    }

    /// Runs a tmux command off the main thread, then refreshes the list.
    public func perform(_ work: @escaping (any TmuxCommands) throws -> Void, then completion: (() -> Void)? = nil) {
        performBackend({ try work($0) }, then: completion)
    }

    /// `perform` for the store's own commands, which use all of the backend.
    private func performBackend(_ work: @escaping (any TmuxBackend) throws -> Void, then completion: (() -> Void)? = nil) {
        let tmux = backend
        scheduler.background {
            let error: Error?
            do { try work(tmux); error = nil } catch let e { error = e }
            self.scheduler.main {
                self.commandError = error.map { "\($0)" }
                self.refresh(then: completion)
            }
        }
    }

    public func dismissCommandError() {
        commandError = nil
    }

    // MARK: Attention

    public func raiseAlert(sessionID: String, message: String?) {
        // A bell right after a notification keeps the notification's text.
        alerts[sessionID] = TerminalAlert(message: message ?? alerts[sessionID]?.message)
    }

    public func clearAlert(sessionID: String) {
        if alerts[sessionID] != nil { alerts[sessionID] = nil }
    }

    public func needsAttention(_ session: TmuxSession) -> Bool {
        alerts[session.id] != nil || session.hasBell
    }

    // MARK: Working

    /// How long a session stays marked as working after its last output.
    static let workingWindow: TimeInterval = 3

    /// The session had output in the last few seconds. Never the selected
    /// one: the user sees that terminal, and their own typing is output too.
    public func isWorking(_ session: TmuxSession) -> Bool {
        session.id != selectedID && working.contains(session.id)
    }

    /// The last value of the activity subscription, by session id.
    private var lastActivity: [String: String] = [:]
    /// Bumped for each mark, so the clearing scheduled by an earlier mark
    /// doesn't clear a later one.
    private var workingMarks: [String: Int] = [:]

    /// The activity subscription's value: "$1=1792598635 1792598640 ;$2=…".
    /// A session whose part changed had output since the last value. The
    /// first value says nothing: a timestamp alone doesn't tell if it's
    /// recent, and the clock isn't ours.
    private func handleActivity(_ value: String) {
        var current: [String: String] = [:]
        for entry in value.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { current[String(parts[0])] = String(parts[1]) }
        }
        let previous = lastActivity
        lastActivity = current
        for (id, times) in current where previous[id] != nil && previous[id] != times {
            markWorking(id)
        }
    }

    private func markWorking(_ id: String) {
        let mark = (workingMarks[id] ?? 0) + 1
        workingMarks[id] = mark
        working.insert(id)
        scheduler.after(Self.workingWindow) { [weak self] in
            guard let self, self.workingMarks[id] == mark else { return }
            self.working.remove(id)
            self.workingMarks[id] = nil
        }
    }

    /// Selects the next (`delta` 1) or previous (-1) session that wants
    /// attention, in sidebar order from the selected one, wrapping around;
    /// the selected session itself doesn't count. False when there is none.
    @discardableResult
    public func selectAttention(_ delta: Int) -> Bool {
        let count = sessions.count
        guard count > 0 else { return false }
        let current = sessions.firstIndex(where: { $0.id == selectedID }) ?? (delta > 0 ? count - 1 : 0)
        for step in 1..<count {
            let session = sessions[((current + delta * step) % count + count) % count]
            if needsAttention(session) {
                selectedID = session.id
                return true
            }
        }
        return false
    }

    // MARK: Windows

    /// Makes a window the session's current one. The tab moves right away;
    /// %session-window-changed then confirms it.
    public func selectWindow(_ windowID: String, in sessionID: String) {
        if let s = sessions.firstIndex(where: { $0.id == sessionID }) {
            for w in sessions[s].windows.indices {
                sessions[s].windows[w].isActive = sessions[s].windows[w].id == windowID
            }
        }
        performBackend { tmux in try tmux.selectWindow(sessionID: sessionID, windowID: windowID) }
    }

    // MARK: Sidebar order and groups

    /// A drag in the sidebar (see SidebarLayout.move).
    public func moveSidebarRow(from source: Int, to destination: Int) {
        let rows = sidebarRows
        changeLayout { $0.move(rows, from: source, to: destination) }
    }

    /// False if a group with that name exists.
    @discardableResult
    public func addGroup(_ name: String, moving sessionID: String? = nil) -> Bool {
        guard !layout.groups.contains(name) else { return false }
        changeLayout { layout in
            layout.addGroup(name)
            if let session = sessions.first(where: { $0.id == sessionID }) {
                layout.setGroup(name, ofSession: session.name)
            }
        }
        return true
    }

    @discardableResult
    public func renameGroup(_ old: String, to new: String) -> Bool {
        guard !layout.groups.contains(new) else { return false }
        changeLayout { $0.renameGroup(old, to: new) }
        return true
    }

    public func removeGroup(_ name: String) {
        changeLayout { $0.removeGroup(name) }
    }

    public func setGroup(_ group: String?, forSession id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        changeLayout { $0.setGroup(group, ofSession: session.name) }
    }

    /// Hides a group's sessions in the sidebar, or shows them again. They
    /// keep their places in `sessions` (⌘1…⌘9, ⌘↑/⌘↓).
    public func toggleGroupCollapsed(_ name: String) {
        changeLayout { $0.setCollapsed(name, !$0.isCollapsed(name)) }
    }

    private func changeLayout(_ change: (inout SidebarLayout) -> Void) {
        var layout = self.layout
        change(&layout)
        guard layout != self.layout else { return }
        setLayout(layout)
        let sorted = layout.sorted(sessions)
        if sorted != sessions { sessions = sorted }
    }

    private func setLayout(_ layout: SidebarLayout) {
        self.layout = layout
        if layoutMayOverwrite, let data = layout.encoded() {
            defaults.set(data, forKey: layoutKey)
        }
    }

    // MARK: Command bar

    /// Runs a command-bar line as the session's active pane, then refreshes.
    public func runCommandLine(_ line: String, in sessionID: String, done: @escaping (Result<String, Error>) -> Void) {
        let tmux = backend
        scheduler.background {
            let result = Result {
                try tmux.runCommandLine(line, pane: try tmux.activePane(sessionID: sessionID))
            }
            self.scheduler.main {
                done(result)
                self.refresh()
            }
        }
    }

    /// Every pane, over the control connection when there is one.
    public func listPanes(_ done: @escaping ([TmuxPane]) -> Void) {
        if let control {
            control.listPanes { done((try? $0.get()) ?? []) }
            return
        }
        let tmux = backend
        scheduler.background {
            let panes = (try? tmux.listPanes()) ?? []
            self.scheduler.main { done(panes) }
        }
    }

    public func selectPane(_ paneID: String) {
        performBackend { tmux in try tmux.selectPane(id: paneID) }
    }

    // MARK: Session templates

    /// The templates, fetched when the palette opens; none without a source
    /// or when listing fails.
    public func listTemplates(_ done: @escaping ([SessionTemplate]) -> Void) {
        guard let templates else { done([]); return }
        scheduler.background {
            let list = (try? templates.list()) ?? []
            self.scheduler.main { done(list) }
        }
    }

    /// Starts the template's session and selects it. The shown session's
    /// active pane goes along so that the template source may switch our
    /// terminal to the new session, as sesh does inside tmux. The source
    /// may report a failure after creating the session (there is no client
    /// to switch when nothing is shown), so the outcome is whether a session
    /// of that name exists afterwards.
    public func startTemplate(_ template: SessionTemplate) {
        guard let templates else { return }
        let tmux = backend
        let selected = selectedID
        scheduler.background {
            let pane = selected.flatMap { try? tmux.activePane(sessionID: $0) }
            let error: Error?
            do { try templates.start(template.name, pane: pane); error = nil } catch let e { error = e }
            self.scheduler.main {
                self.refresh {
                    if let session = self.sessions.first(where: { $0.name == template.name }) {
                        self.commandError = nil
                        self.selectedID = session.id
                    } else {
                        self.commandError = error.map { "\($0)" } ?? "sesh did not create a session named \(template.name)"
                    }
                }
            }
        }
    }

    public func listCommands(_ done: @escaping ([TmuxCommand]) -> Void) {
        let tmux = backend
        scheduler.background {
            let commands = (try? tmux.listCommands()) ?? []
            self.scheduler.main { done(commands) }
        }
    }

    // MARK: Control mode

    /// Switches from polling to events once there is a session to attach to.
    private func connectIfPossible() {
        guard control == nil, let first = sessions.first else { return }
        let client: any TmuxControlConnection
        do {
            client = try makeControl(first.id)
        } catch {
            TmuxControlClient.log.error("tmux -C failed to start: \(String(describing: error), privacy: .public)")
            connectionError = "tmux control mode: \(error)"
            return
        }
        client.onNotification = { [weak self] name, args in
            self?.handleNotification(name, args)
        }
        client.onExit = { [weak self, weak client] in
            guard let self, let client, self.control === client else { return }
            self.control = nil
            self.isLive = false
            self.startPolling()
            self.refresh()
        }
        control = client
        connectionError = nil
        isLive = true
        endPolling()
        // Pick up anything that changed between the CLI query and attaching.
        refresh()
    }

    private func handleNotification(_ name: String, _ args: [String]) {
        if name == "%client-session-changed", args.count >= 2 {
            onClientSessionChanged?(args[0], args[1])
        }
        // The session keeps its sidebar place under the new name. Only from
        // the event: ids are reused after a server restart, so a changed
        // name for an id isn't proof of a rename. The name changes here too,
        // or the row would jump to the end until the refresh.
        if name == "%session-renamed", args.count >= 2,
           let index = sessions.firstIndex(where: { $0.id == args[0] }) {
            let old = sessions[index]
            let newName = args.dropFirst().joined(separator: " ")
            var layout = self.layout
            layout.renameSession(old.name, to: newName)
            setLayout(layout)
            sessions[index] = TmuxSession(id: old.id, name: newName, windows: old.windows,
                                          attachedClients: old.attachedClients)
        }
        if name == "%subscription-changed", args.first == "activity" {
            // "activity $id - - - : value"
            if let colon = args.firstIndex(of: ":") {
                handleActivity(args[(colon + 1)...].joined(separator: " "))
            }
            return
        }
        if Self.listEvents.contains(name) {
            scheduleRefresh()
        }
    }

    /// Coalesces bursts: killing a session sends several notifications.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        scheduler.after(0.05) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func startPolling() {
        guard stopPolling == nil else { return }
        stopPolling = scheduler.every(1.0) { [weak self] in
            self?.refresh()
        }
    }

    private func endPolling() {
        stopPolling?()
        stopPolling = nil
    }

    // MARK: State

    private func apply(_ result: Result<[TmuxSession], Error>) {
        switch result {
        case .success(var sessions):
            listError = nil
            if let placeholder = restorePlaceholderID {
                if sessions.contains(where: { $0.id == placeholder }) {
                    sessions.removeAll { $0.id == placeholder }
                } else {
                    endRestore() // tmux-resurrect removed it: restore done
                }
            }
            var layout = self.layout
            let names = sessions.map(\.name)
            let now = Date()
            layout.include(names, now: now)
            layout = layout.pruned(now: now, present: Set(names))
            if layout != self.layout { setLayout(layout) }
            sessions = layout.sorted(sessions)
            if sessions != self.sessions { self.sessions = sessions }
            let ids = Set(sessions.map(\.id))
            if alerts.keys.contains(where: { !ids.contains($0) }) { alerts = alerts.filter { ids.contains($0.key) } }
            if working.contains(where: { !ids.contains($0) }) { working = working.filter { ids.contains($0) } }
            recentIDs.removeAll { !ids.contains($0) }
            fixSelection()
        case .failure(let error):
            listError = "\(error)"
        }
    }

    private func fixSelection() {
        let remembered = defaults.string(forKey: lastSessionKey)
        if selectionIsAutomatic, let match = sessions.first(where: { $0.name == remembered }) {
            if match.id != selectedID { selectAutomatically(match.id) }
            return
        }
        if let id = selectedID, sessions.contains(where: { $0.id == id }) { return }
        selectAutomatically(sessions.first?.id)
    }

    private func selectAutomatically(_ id: String?) {
        selectingAutomatically = true
        selectedID = id
        selectingAutomatically = false
        selectionIsAutomatic = true
    }
}

public struct TerminalAlert: Equatable {
    /// A desktop notification's text; nil for a plain bell.
    public var message: String?
}
