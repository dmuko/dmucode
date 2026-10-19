import Foundation
import os

/// A tmux control-mode client (`tmux -C attach-session`) used for
/// notifications and queries, never for pane output. The protocol itself is
/// in ControlModeParser.
///
/// Connection events go to the unified log (subsystem dev.dmucode.app,
/// category control), notifications and commands at debug level.
final class TmuxControlClient {
    /// A notification's name (e.g. "%sessions-changed") and arguments. Main thread.
    var onNotification: ((String, [String]) -> Void)?
    /// The connection ended: tmux server exited, last session killed, or no
    /// reply came (see `checkHeartbeat`). Main thread.
    var onExit: (() -> Void)?

    static let log = Logger(subsystem: "dev.dmucode.app", category: "control")

    /// A stalled connection never closes, so exit and EOF can't reveal it; a
    /// command without a reply can. Every interval, give up if the oldest
    /// reply is overdue, and otherwise send a no-op if nothing is pending.
    /// A stall is therefore noticed 10-20 s after it starts.
    private static let heartbeatInterval: TimeInterval = 10
    private static let replyTimeout: Duration = .seconds(5)

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var heartbeat: DispatchSourceTimer?

    // Only touched from the output handle's reader queue.
    private var parser = ControlModeParser()

    // Replies arrive in the order commands were sent. SuspendingClock, like
    // the heartbeat timer, stands still while the Mac sleeps, so a command
    // sent just before sleep isn't overdue on wake.
    private let lock = NSLock()
    private var pending: [(sent: SuspendingClock.Instant, reply: (Result<[String], TmuxError>) -> Void)] = []
    private var exited = false

    init(tmux: Tmux, sessionID: String) throws {
        process.executableURL = URL(fileURLWithPath: tmux.executable)
        process.arguments = tmux.globalArgs + ["-C", "attach-session", "-t", sessionID]
        process.environment = tmux.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
            Self.log.notice("tmux -C (pid \(process.processIdentifier)) exited, \(how, privacy: .public) \(process.terminationStatus)")
            self?.finish()
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.consume(data)
            }
        }
        try process.run()
        Self.log.notice("tmux -C (pid \(self.process.processIdentifier)) attached to session \(sessionID, privacy: .public)")

        // no-output: pane output of the attached session would otherwise
        // stream here. ignore-size: stay out of window sizing.
        // no-detach-on-destroy: move to another session instead of exiting
        // when ours is killed. Separate commands so an older tmux that lacks
        // one flag still accepts the others.
        for flag in ["no-output", "ignore-size", "no-detach-on-destroy"] {
            send(["refresh-client", "-f", flag])
        }
        // A `cd` or a bell sends no notification. tmux checks a subscription
        // about once a second and sends %subscription-changed when its value
        // changes; this one covers every window's path and alert flags in
        // every session.
        send(["refresh-client", "-B",
              "windows::#{S:#{W:#{window_id}=#{window_bell_flag}#{window_activity_flag}#{pane_current_path};}}"])

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dmucode.tmux-control.heartbeat"))
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.checkHeartbeat() }
        timer.resume()
        heartbeat = timer
    }

    deinit {
        heartbeat?.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        close()
    }

    /// Detaches: tmux ends a control client when its stdin closes.
    func close() {
        try? input.fileHandleForWriting.close()
    }

    /// Sends one command; `reply` receives its output lines on the main thread.
    func send(_ args: [String], reply: ((Result<[String], TmuxError>) -> Void)? = nil) {
        let line = args.map(Self.quote).joined(separator: " ") + "\n"
        Self.log.debug("> \(String(line.dropLast()), privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        do {
            guard !exited else { throw TmuxError(description: "tmux control client has exited") }
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            pending.append((sent: .now, reply: reply ?? { _ in }))
        } catch {
            let failure = TmuxError(description: "\(error)")
            DispatchQueue.main.async { reply?(.failure(failure)) }
        }
    }

    /// The sessions and their windows, queried over this connection.
    func listSessions(_ completion: @escaping (Result<[TmuxSession], TmuxError>) -> Void) {
        var sessions: Result<[String], TmuxError> = .success([])
        var windows: Result<[String], TmuxError> = .success([])
        send(Tmux.listSessionsArgs) { sessions = $0 }
        send(Tmux.listWindowsArgs) { windows = $0 }
        send(Tmux.listClientsArgs) { clients in
            completion(sessions.flatMap { sessionLines in
                windows.flatMap { windowLines in
                    clients.map { Tmux.parseSessions(sessions: sessionLines, windows: windowLines, clients: $0) }
                }
            })
        }
    }

    // MARK: Reading

    private func consume(_ data: Data) {
        for event in parser.consume(data) {
            switch event {
            case .reply(let result):
                if let reply = popPending() {
                    DispatchQueue.main.async { reply(result) }
                }
            case .notification(let name, let args):
                Self.log.debug("< \(name, privacy: .public) \(args.joined(separator: " "), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.onNotification?(name, args)
                }
            }
        }
    }

    private func popPending() -> ((Result<[String], TmuxError>) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst().reply
    }

    // MARK: Heartbeat

    private func checkHeartbeat() {
        lock.lock()
        let oldest = exited ? nil : pending.first?.sent
        let idle = !exited && pending.isEmpty
        lock.unlock()

        if let oldest, SuspendingClock.now - oldest > Self.replyTimeout {
            let pid = process.processIdentifier
            let waited = SuspendingClock.now - oldest
            Self.log.error("tmux -C (pid \(pid)): no reply for \(waited, privacy: .public), reconnecting")
            // SIGKILL: a stalled client may never get to handle SIGTERM.
            kill(pid, SIGKILL)
            finish()
        } else if idle {
            send(["display-message", "-p", "ok"])
        }
    }

    /// Runs once, whichever comes first: exit, or a stall.
    private func finish() {
        lock.lock()
        guard !exited else { lock.unlock(); return }
        exited = true
        let replies = pending.map(\.reply)
        pending.removeAll()
        lock.unlock()
        heartbeat?.cancel()

        DispatchQueue.main.async { [weak self] in
            // onExit first: the store then ignores the failed replies
            // instead of showing "has exited" until polling catches up.
            self?.onExit?()
            let failure = TmuxError(description: "tmux control client has exited")
            replies.forEach { $0(.failure(failure)) }
        }
    }

    /// Quotes an argument for tmux's command parser.
    private static func quote(_ arg: String) -> String {
        if !arg.contains("'") { return "'" + arg + "'" }
        let escaped = arg
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
        return "\"" + escaped + "\""
    }
}

/// The control-mode protocol (tmux(1), CONTROL MODE), apart from the
/// process: each command's reply is framed by `%begin <time> <number> <flags>`
/// … `%end|%error <time> <number> <flags>`, where flags is 1 for commands
/// this client sent. Lines outside a block are notifications such as
/// `%sessions-changed`.
struct ControlModeParser {
    enum Event: Equatable {
        /// The reply to the oldest command this client sent that has none yet.
        case reply(Result<[String], TmuxError>)
        /// A notification's name (e.g. "%sessions-changed") and arguments.
        case notification(name: String, args: [String])
    }

    private var buffer = Data()
    private var block: (number: Substring, ours: Bool, lines: [String])?

    /// The events in the lines completed by `data`; a partial line waits
    /// for the rest.
    mutating func consume(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = handle(line) { events.append(event) }
        }
        return events
    }

    private mutating func handle(_ line: String) -> Event? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)

        if let current = block {
            // Only a guard line with the same command number ends the block;
            // command output itself may start with "%".
            guard let guardName = fields.first, guardName == "%end" || guardName == "%error",
                  fields.count >= 3, fields[2] == current.number else {
                block?.lines.append(line)
                return nil
            }
            block = nil
            guard current.ours else { return nil }
            return .reply(guardName == "%end"
                ? .success(current.lines)
                : .failure(TmuxError(description: current.lines.joined(separator: "\n"))))
        }

        guard let name = fields.first, name.hasPrefix("%") else { return nil }
        switch name {
        case "%begin":
            if fields.count >= 4 { block = (fields[2], fields[3] == "1", []) }
            return nil
        case "%output", "%extended-output":
            // Only possible before no-output takes effect.
            return nil
        default:
            return .notification(name: String(name), args: fields.dropFirst().map(String.init))
        }
    }
}
