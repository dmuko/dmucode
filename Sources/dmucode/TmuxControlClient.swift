import Foundation

/// A tmux control-mode client (`tmux -C attach-session`) used for
/// notifications and queries, never for pane output.
///
/// Protocol (tmux(1), CONTROL MODE): each command's reply is framed by
/// `%begin <time> <number> <flags>` … `%end|%error <time> <number> <flags>`,
/// where flags is 1 for commands this client sent. Lines outside a block are
/// notifications such as `%sessions-changed`.
final class TmuxControlClient {
    /// A notification's name (e.g. "%sessions-changed") and arguments. Main thread.
    var onNotification: ((String, [String]) -> Void)?
    /// The connection ended: tmux server exited, last session killed... Main thread.
    var onExit: (() -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    // Only touched from the output handle's reader queue.
    private var buffer = Data()
    private var block: (number: Substring, ours: Bool, lines: [String])?

    // Replies arrive in the order commands were sent.
    private let lock = NSLock()
    private var pending: [(Result<[String], TmuxError>) -> Void] = []
    private var exited = false

    init(tmux: Tmux, sessionID: String) throws {
        process.executableURL = URL(fileURLWithPath: tmux.executable)
        process.arguments = tmux.globalArgs + ["-C", "attach-session", "-t", sessionID]
        process.environment = tmux.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.finish() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.consume(data)
            }
        }
        try process.run()

        // no-output: pane output of the attached session would otherwise
        // stream here. ignore-size: stay out of window sizing.
        // no-detach-on-destroy: move to another session instead of exiting
        // when ours is killed. Separate commands so an older tmux that lacks
        // one flag still accepts the others.
        for flag in ["no-output", "ignore-size", "no-detach-on-destroy"] {
            send(["refresh-client", "-f", flag])
        }
    }

    deinit {
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
        lock.lock()
        defer { lock.unlock() }
        do {
            guard !exited else { throw TmuxError(description: "tmux control client has exited") }
            try input.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            pending.append(reply ?? { _ in })
        } catch {
            let failure = TmuxError(description: "\(error)")
            DispatchQueue.main.async { reply?(.failure(failure)) }
        }
    }

    /// The sidebar's session list, queried over this connection.
    func listSessions(_ completion: @escaping (Result<[TmuxSession], TmuxError>) -> Void) {
        var sessions: Result<[String], TmuxError> = .success([])
        send(Tmux.listSessionsArgs) { sessions = $0 }
        send(Tmux.listClientsArgs) { clients in
            completion(sessions.flatMap { sessionLines in
                clients.map { Tmux.parseSessions(sessions: sessionLines, clients: $0) }
            })
        }
    }

    // MARK: Reading

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)

        if let current = block {
            // Only a guard line with the same command number ends the block;
            // command output itself may start with "%".
            if let guardName = fields.first, guardName == "%end" || guardName == "%error",
               fields.count >= 3, fields[2] == current.number {
                block = nil
                guard current.ours else { return }
                let result: Result<[String], TmuxError> = guardName == "%end"
                    ? .success(current.lines)
                    : .failure(TmuxError(description: current.lines.joined(separator: "\n")))
                if let reply = popPending() {
                    DispatchQueue.main.async { reply(result) }
                }
            } else {
                block?.lines.append(line)
            }
            return
        }

        guard let name = fields.first, name.hasPrefix("%") else { return }
        switch name {
        case "%begin":
            guard fields.count >= 4 else { return }
            block = (fields[2], fields[3] == "1", [])
        case "%output", "%extended-output":
            // Only possible before no-output takes effect.
            return
        default:
            let args = fields.dropFirst().map(String.init)
            DispatchQueue.main.async { [weak self] in
                self?.onNotification?(String(name), args)
            }
        }
    }

    private func popPending() -> ((Result<[String], TmuxError>) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func finish() {
        lock.lock()
        exited = true
        let replies = pending
        pending.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            let failure = TmuxError(description: "tmux control client has exited")
            replies.forEach { $0(.failure(failure)) }
            self?.onExit?()
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
