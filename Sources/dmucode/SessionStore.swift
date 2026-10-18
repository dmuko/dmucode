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
            if let name = sessions.first(where: { $0.id == selectedID })?.name {
                UserDefaults.standard.set(name, forKey: Self.lastSessionKey)
            }
        }
    }
    @Published private(set) var errorMessage: String?
    /// True while updates arrive as control-mode events, false while polling.
    @Published private(set) var isLive = false

    /// A tmux client moved to another session (prefix s, switch-client...):
    /// the client's tty and the new session id.
    var onClientSessionChanged: ((_ tty: String, _ sessionID: String) -> Void)?

    let tmux: Tmux
    private let queue = DispatchQueue(label: "dmucode.tmux")
    private var control: TmuxControlClient?
    private var pollTimer: Timer?
    private var cliRefreshing = false
    private var refreshScheduled = false
    private var loadedOnce = false

    /// Remembered by name: ids change when the tmux server restarts (e.g.
    /// after tmux-resurrect), names survive.
    private static let lastSessionKey = "lastSessionName"

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
        refresh()
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
        case .success(let sessions):
            errorMessage = nil
            if sessions != self.sessions { self.sessions = sessions }
            fixSelection()
        case .failure(let error):
            errorMessage = "\(error)"
        }
    }

    private func fixSelection() {
        if !loadedOnce {
            loadedOnce = true
            let last = UserDefaults.standard.string(forKey: Self.lastSessionKey)
            selectedID = sessions.first(where: { $0.name == last })?.id ?? sessions.first?.id
            return
        }
        if let id = selectedID, sessions.contains(where: { $0.id == id }) { return }
        selectedID = sessions.first?.id
    }
}
