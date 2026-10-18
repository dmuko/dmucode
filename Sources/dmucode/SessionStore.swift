import Foundation

/// The sidebar's model: the tmux server's sessions.
///
/// Updates are event-driven through a tmux control-mode connection: a
/// notification such as %sessions-changed triggers a re-query over the same
/// connection. A control client has to attach to some session, so while the
/// server has none (or isn't running) the store polls the CLI once a second
/// and connects as soon as a session appears. All state is touched on the
/// main thread.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TmuxSession] = []
    @Published var selectedID: String? {
        didSet {
            guard !selectingAutomatically else { return }
            // A choice by the user (sidebar, shortcut, switching inside tmux)
            // is the session to come back to next time.
            selectionIsAutomatic = false
            if let name = sessions.first(where: { $0.id == selectedID })?.name {
                UserDefaults.standard.set(name, forKey: lastSessionKey)
            }
        }
    }
    @Published private(set) var errorMessage: String?
    /// True while updates arrive as control-mode events, false while polling.
    @Published private(set) var isLive = false
    /// True while tmux-continuum restores sessions after we started the server.
    @Published private(set) var isRestoring = false

    /// A tmux client moved to another session (prefix s, switch-client...):
    /// the client's tty and the new session id.
    var onClientSessionChanged: ((_ tty: String, _ sessionID: String) -> Void)?

    let tmux: Tmux
    private let queue = DispatchQueue(label: "dmucode.tmux")
    private var control: TmuxControlClient?
    private var pollTimer: Timer?
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
        "lastSessionName" + (tmux.socketName.map { "-" + $0 } ?? "")
    }

    /// Notifications after which the session list (names, window counts,
    /// attached clients) may have changed.
    private static let listEvents: Set<String> = [
        "%sessions-changed", "%session-renamed", "%session-changed",
        "%client-session-changed", "%client-detached",
        "%window-add", "%window-close", "%unlinked-window-add", "%unlinked-window-close",
    ]

    init(tmux: Tmux) {
        self.tmux = tmux
    }

    func start() {
        startPolling()
        let tmux = self.tmux
        queue.async {
            // After a reboot there is no tmux server. If tmux-resurrect has a
            // save, start the server so tmux-continuum restores it.
            var placeholder: String?
            if tmux.hasResurrectSave, (try? tmux.isServerRunning()) == false {
                placeholder = try? tmux.startServerForRestore()
            }
            DispatchQueue.main.async {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.restorePlaceholderID == placeholder else { return }
            self.endRestore()
            self.refresh()
        }
    }

    private func endRestore() {
        restorePlaceholderID = nil
        isRestoring = false
    }

    func refresh(then completion: (() -> Void)? = nil) {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refresh(then: completion) }
            }
            return
        }
        cliRefreshing = true
        let tmux = self.tmux
        queue.async {
            let result = Result { try tmux.listSessions() }
            DispatchQueue.main.async {
                self.cliRefreshing = false
                self.apply(result)
                self.connectIfPossible()
                completion?()
            }
        }
    }

    /// Runs a tmux command off the main thread, then refreshes the list.
    func perform(_ work: @escaping (Tmux) throws -> Void, then completion: (() -> Void)? = nil) {
        let tmux = self.tmux
        queue.async {
            let error: Error?
            do { try work(tmux); error = nil } catch let e { error = e }
            DispatchQueue.main.async {
                if let error { self.errorMessage = "\(error)" }
                self.refresh(then: completion)
            }
        }
    }

    // MARK: Control mode

    /// Switches from polling to events once there is a session to attach to.
    private func connectIfPossible() {
        guard control == nil, let first = sessions.first else { return }
        let client: TmuxControlClient
        do {
            client = try TmuxControlClient(tmux: tmux, sessionID: first.id)
        } catch {
            errorMessage = "tmux control mode: \(error)"
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
        isLive = true
        stopPolling()
        // Pick up anything that changed between the CLI query and attaching.
        refresh()
    }

    private func handleNotification(_ name: String, _ args: [String]) {
        if name == "%client-session-changed", args.count >= 2 {
            onClientSessionChanged?(args[0], args[1])
        }
        if Self.listEvents.contains(name) {
            scheduleRefresh()
        }
    }

    /// Coalesces bursts: killing a session sends several notifications.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: State

    private func apply(_ result: Result<[TmuxSession], Error>) {
        switch result {
        case .success(var sessions):
            errorMessage = nil
            if let placeholder = restorePlaceholderID {
                if sessions.contains(where: { $0.id == placeholder }) {
                    sessions.removeAll { $0.id == placeholder }
                } else {
                    endRestore() // tmux-resurrect removed it: restore done
                }
            }
            if sessions != self.sessions { self.sessions = sessions }
            fixSelection()
        case .failure(let error):
            errorMessage = "\(error)"
        }
    }

    private func fixSelection() {
        let remembered = UserDefaults.standard.string(forKey: lastSessionKey)
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
