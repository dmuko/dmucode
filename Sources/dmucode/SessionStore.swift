import Foundation

/// The sidebar's model: tmux sessions, polled once a second. Polling keeps
/// the prototype simple; a `tmux -C` client listening for %sessions-changed
/// would be the event-driven upgrade. All state is touched on the main thread.
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

    let tmux: Tmux
    private let queue = DispatchQueue(label: "dmucode.tmux")
    private var timer: Timer?
    private var refreshing = false
    private var loadedOnce = false

    /// Remembered by name: ids change when the tmux server restarts (e.g.
    /// after tmux-resurrect), names survive.
    private static let lastSessionKey = "lastSessionName"

    init(tmux: Tmux) {
        self.tmux = tmux
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh(then completion: (() -> Void)? = nil) {
        guard !refreshing else {
            // Retry shortly so a completion is never dropped.
            if let completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refresh(then: completion) }
            }
            return
        }
        refreshing = true
        let tmux = self.tmux
        queue.async {
            let result = Result { try tmux.listSessions() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let sessions):
                    self.errorMessage = nil
                    if sessions != self.sessions { self.sessions = sessions }
                    self.fixSelection()
                case .failure(let error):
                    self.errorMessage = "\(error)"
                }
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
