import Foundation
@testable import dmucodeCore

/// A tmux that lives in memory: the sessions it lists, and the failures to
/// report. Everything SessionStore asks of the CLI goes through here.
final class FakeTmux: TmuxBackend {
    var socketName: String? = "test"
    var sessions: [TmuxSession] = []
    var listError: TmuxError?
    var hasResurrectSave = false
    var serverRunning = true
    /// What startServerForRestore adds, and returns the id of.
    var placeholder = TmuxSession(id: "$0", name: "0", windows: [], attachedClients: 0)

    private(set) var listCount = 0
    private(set) var startedServer = false
    private(set) var calls: [String] = []

    func listSessions() throws -> [TmuxSession] {
        listCount += 1
        if let listError { throw listError }
        return sessions
    }
    func isServerRunning() throws -> Bool { serverRunning }
    func startServerForRestore() throws -> String {
        startedServer = true
        serverRunning = true
        sessions.append(placeholder)
        return placeholder.id
    }

    func listPanes() throws -> [TmuxPane] { [] }
    func listCommands() throws -> [TmuxCommand] { [] }
    func selectWindow(sessionID: String, windowID: String) throws { calls.append("select-window \(sessionID) \(windowID)") }
    func selectPane(id: String) throws { calls.append("select-pane \(id)") }
    func activePane(sessionID: String) throws -> String { "%0" }
    func runCommandLine(_ line: String, pane: String) throws -> String { "" }

    func newSession(name: String?, directory: String) throws -> String { "$new" }
    func renameSession(id: String, to name: String) throws { calls.append("rename-session \(id) \(name)") }
    func killSession(id: String) throws { calls.append("kill-session \(id)") }
    func newWindow(sessionID: String) throws { calls.append("new-window \(sessionID)") }
    func renameWindow(sessionID: String, windowID: String, to name: String) throws {}
    func killWindow(sessionID: String, windowID: String) throws {}
    func attachCommand(sessionID: String) -> String { "attach \(sessionID)" }
}

/// A control connection whose replies come from the fake tmux, or are held
/// until the test releases them.
final class FakeControl: TmuxControlConnection {
    var onNotification: ((String, [String]) -> Void)?
    var onExit: (() -> Void)?

    let sessionID: String
    private let tmux: FakeTmux
    private let scheduler: ManualScheduler
    private(set) var listCount = 0
    /// Keep the replies instead of answering; see `answerHeld`.
    var holdReplies = false
    private var held: [(Result<[TmuxSession], TmuxError>) -> Void] = []

    init(sessionID: String, tmux: FakeTmux, scheduler: ManualScheduler) {
        self.sessionID = sessionID
        self.tmux = tmux
        self.scheduler = scheduler
    }

    func listSessions(_ completion: @escaping (Result<[TmuxSession], TmuxError>) -> Void) {
        listCount += 1
        guard !holdReplies else { held.append(completion); return }
        let result: Result<[TmuxSession], TmuxError> = tmux.listError.map { .failure($0) } ?? .success(tmux.sessions)
        scheduler.main { completion(result) }
    }
    func listPanes(_ completion: @escaping (Result<[TmuxPane], TmuxError>) -> Void) {
        scheduler.main { completion(.success([])) }
    }

    func answerHeld(_ result: Result<[TmuxSession], TmuxError>) {
        let replies = held
        held = []
        for reply in replies { reply(result) }
    }

    func notify(_ name: String, _ args: [String] = []) { onNotification?(name, args) }
    func exit() { onExit?() }
}

/// Time that stands still until the test moves it. `background` runs at once,
/// so there are no threads; everything meant for the main thread waits for
/// `run`.
final class ManualScheduler: StoreScheduler {
    private struct Task {
        var due: TimeInterval
        var order: Int
        var work: () -> Void
        var repeating: TimeInterval?
        var timer: Int?
    }

    private(set) var now: TimeInterval = 0
    private var tasks: [Task] = []
    private var counter = 0
    private var cancelled: Set<Int> = []

    func background(_ work: @escaping () -> Void) { work() }
    func main(_ work: @escaping () -> Void) { add(0, work) }
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) { add(delay, work) }
    func every(_ interval: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let id = counter
        add(interval, work, repeating: interval, timer: id)
        return { [weak self] in self?.cancelled.insert(id) }
    }

    /// Repeating timers that are still running.
    var activeTimers: Int {
        Set(tasks.compactMap(\.timer)).subtracting(cancelled).count
    }

    private func add(_ delay: TimeInterval, _ work: @escaping () -> Void, repeating: TimeInterval? = nil, timer: Int? = nil) {
        tasks.append(Task(due: now + delay, order: counter, work: work, repeating: repeating, timer: timer))
        counter += 1
    }

    /// Runs what is due now, and then whatever falls due within `seconds`,
    /// in order of time. Work that work adds runs too, if due in time.
    func run(for seconds: TimeInterval = 0) {
        let end = now + seconds
        while let index = tasks.indices.filter({ tasks[$0].due <= end })
            .min(by: { (tasks[$0].due, tasks[$0].order) < (tasks[$1].due, tasks[$1].order) }) {
            var task = tasks.remove(at: index)
            if let timer = task.timer, cancelled.contains(timer) { continue }
            now = max(now, task.due)
            if let interval = task.repeating {
                task.due += interval
                task.order = counter
                counter += 1
                tasks.append(task)
            }
            task.work()
        }
        now = end
    }
}

/// A SessionStore on the fakes, with user defaults of its own.
final class StoreHarness {
    let tmux = FakeTmux()
    let scheduler = ManualScheduler()
    let defaults: UserDefaults
    private let suite = "dmucode-tests-" + UUID().uuidString
    private(set) var controls: [FakeControl] = []
    /// While set, starting a control client fails with it.
    var controlFailure: Error?
    private(set) var store: SessionStore!

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Creates the store; call after setting up `defaults` and `tmux`.
    @discardableResult
    func makeStore() -> SessionStore {
        store = SessionStore(
            backend: tmux,
            makeControl: { [unowned self] id in
                if let controlFailure { throw controlFailure }
                let control = FakeControl(sessionID: id, tmux: tmux, scheduler: scheduler)
                controls.append(control)
                return control
            },
            scheduler: scheduler,
            defaults: defaults)
        return store
    }

    /// Starts the store and lets the first refresh through.
    func start() {
        if store == nil { makeStore() }
        store.start()
        scheduler.run()
    }

    var control: FakeControl? { controls.last }
    var lastSessionName: String? { defaults.string(forKey: "lastSessionName-test") }

    func refresh() {
        store.refresh()
        scheduler.run()
    }
}

func session(_ name: String, bell: Bool = false) -> TmuxSession {
    let window = TmuxWindow(id: "@" + name, index: 0, name: "w", isActive: true, path: "/", hasBell: bell)
    return TmuxSession(id: "$" + name, name: name, windows: [window], attachedClients: 0)
}
