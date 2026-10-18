import Foundation

struct TmuxSession: Identifiable, Equatable {
    /// tmux's session id, e.g. "$3". Stable across renames, unlike the name.
    let id: String
    let name: String
    let windows: Int
    let attachedClients: Int
}

struct TmuxError: Error, CustomStringConvertible {
    let description: String
}

/// Thin wrapper over the tmux CLI. Calls block, so run them off the main thread.
struct Tmux {
    /// Absolute path: apps started from Finder don't inherit the shell's PATH.
    let executable: String
    /// `-L` socket name from DMUCODE_TMUX_SOCKET; nil means the default server.
    let socketName: String?

    static func resolve() -> Tmux? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["DMUCODE_TMUX"], "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let executable = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let socket = env["DMUCODE_TMUX_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        return Tmux(executable: executable, socketName: socket)
    }

    var globalArgs: [String] { socketName.map { ["-L", $0] } ?? [] }

    // The sidebar query, shared by the CLI and the control-mode client. The
    // name goes last so it may contain spaces; control clients (our own
    // `tmux -C`) are not counted as attached.
    static let listSessionsArgs = ["list-sessions", "-F", "#{session_id} #{session_windows} #{session_name}"]
    static let listClientsArgs = ["list-clients", "-F", "#{session_id} #{client_control_mode}"]

    static func parseSessions(sessions: [String], clients: [String]) -> [TmuxSession] {
        var attached: [String: Int] = [:]
        for line in clients {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[1] == "0" { attached[String(fields[0]), default: 0] += 1 }
        }
        return sessions.compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let id = String(fields[0])
            return TmuxSession(
                id: id,
                name: String(fields[2]),
                windows: Int(fields[1]) ?? 0,
                attachedClients: attached[id] ?? 0)
        }
    }

    func listSessions() throws -> [TmuxSession] {
        let sessions = try run(Self.listSessionsArgs)
        if sessions.status != 0 {
            // No server yet simply means no sessions.
            if sessions.stderr.contains("no server running") || sessions.stderr.contains("error connecting") {
                return []
            }
            throw TmuxError(description: sessions.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let clients = try run(Self.listClientsArgs)
        return Self.parseSessions(
            sessions: sessions.stdout.split(separator: "\n").map(String.init),
            clients: clients.stdout.split(separator: "\n").map(String.init))
    }

    /// Creates a detached session and returns its id.
    func newSession(name: String?, directory: String) throws -> String {
        var args = ["new-session", "-d", "-P", "-F", "#{session_id}", "-c", directory]
        if let name, !name.isEmpty { args += ["-s", name] }
        let result = try run(args)
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func renameSession(id: String, to name: String) throws {
        let result = try run(["rename-session", "-t", id, name])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    func isServerRunning() throws -> Bool {
        let result = try run(["list-sessions"])
        if result.status == 0 { return true }
        if result.stderr.contains("no server running") || result.stderr.contains("error connecting") { return false }
        throw TmuxError(description: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether tmux-resurrect has a save to restore. `@resurrect-dir` can't
    /// be read without a running server, so this checks resurrect's default
    /// directories, or DMUCODE_RESURRECT_DIR (used by tests).
    var hasResurrectSave: Bool {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let dirs = env["DMUCODE_RESURRECT_DIR"].map { [$0] } ?? [
            home + "/.tmux/resurrect",
            (env["XDG_DATA_HOME"] ?? home + "/.local/share") + "/tmux/resurrect",
        ]
        // `last` links to the newest save; fileExists follows the link.
        return dirs.contains { FileManager.default.fileExists(atPath: $0 + "/last") }
    }

    /// Starts the tmux server with a throwaway session and returns its id.
    /// With `@continuum-restore 'on'`, tmux-continuum restores the last save
    /// when the server starts, and tmux-resurrect then kills the throwaway
    /// session (tmux names it "0").
    func startServerForRestore() throws -> String {
        let result = try run(["new-session", "-d", "-P", "-F", "#{session_id}"])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func killSession(id: String) throws {
        let result = try run(["kill-session", "-t", id])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    /// The shell command a terminal surface runs to show a session.
    func attachCommand(sessionID: String) -> String {
        ([executable] + globalArgs + ["attach-session", "-t", sessionID])
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The environment for tmux processes started by the app. A tmux server
    /// started from here inherits it, so give it a usable PATH even when the
    /// app was launched from Finder.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // tmux configs often set default-terminal to xterm-ghostty, which
        // panes can only resolve if the server knows where its terminfo is.
        if env["TERMINFO"] == nil, let terminfo = Bundle.main.resourceURL?.appendingPathComponent("terminfo").path,
           FileManager.default.fileExists(atPath: terminfo) {
            env["TERMINFO"] = terminfo
        }
        return env
    }

    private func run(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = globalArgs + args

        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: stdout, as: UTF8.self),
                String(decoding: stderr, as: UTF8.self))
    }
}
