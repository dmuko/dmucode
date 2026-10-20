import Foundation

// What SessionStore needs from tmux and from the machine's clocks, as
// protocols, so tests can run it against a fake tmux and a manual scheduler.
// The real `Tmux`, `TmuxControlClient` and `DispatchScheduler` conform; the
// app doesn't see the difference.

/// The one-off tmux commands the app's `SessionStore.perform` closures run.
public protocol TmuxCommands {
    var socketName: String? { get }
    func newSession(name: String?, directory: String) throws -> String
    func renameSession(id: String, to name: String) throws
    func killSession(id: String) throws
    func newWindow(sessionID: String) throws
    func renameWindow(sessionID: String, windowID: String, to name: String) throws
    func killWindow(sessionID: String, windowID: String) throws
    func attachCommand(sessionID: String) -> String
}

/// Everything else SessionStore asks of the tmux CLI. Blocking calls; the
/// store makes them off the main thread.
protocol TmuxBackend: TmuxCommands {
    func listSessions() throws -> [TmuxSession]
    func listPanes() throws -> [TmuxPane]
    func listCommands() throws -> [TmuxCommand]
    func selectWindow(sessionID: String, windowID: String) throws
    func selectPane(id: String) throws
    func activePane(sessionID: String) throws -> String
    func runCommandLine(_ line: String, pane: String) throws -> String
    /// For the restore at launch (see SessionStore.start).
    var hasResurrectSave: Bool { get }
    func isServerRunning() throws -> Bool
    func startServerForRestore() throws -> String
}

extension Tmux: TmuxBackend {}

/// A control-mode connection as SessionStore uses it. Callbacks on the main thread.
protocol TmuxControlConnection: AnyObject {
    var onNotification: ((String, [String]) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func listSessions(_ completion: @escaping (Result<[TmuxSession], TmuxError>) -> Void)
    func listPanes(_ completion: @escaping (Result<[TmuxPane], TmuxError>) -> Void)
}

extension TmuxControlClient: TmuxControlConnection {}

/// Where SessionStore's work runs and when. Production dispatches onto the
/// real queues and run loop; tests step a manual clock.
protocol StoreScheduler: AnyObject {
    /// Off the main thread, in order (tmux CLI calls).
    func background(_ work: @escaping () -> Void)
    /// On the main thread, later.
    func main(_ work: @escaping () -> Void)
    /// On the main thread after a delay in seconds.
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void)
    /// On the main thread every interval seconds. Returns the way to stop it.
    func every(_ interval: TimeInterval, _ work: @escaping () -> Void) -> () -> Void
}

final class DispatchScheduler: StoreScheduler {
    private let queue = DispatchQueue(label: "dmucode.tmux")

    func background(_ work: @escaping () -> Void) { queue.async(execute: work) }
    func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func every(_ interval: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in work() }
        return { timer.invalidate() }
    }
}
