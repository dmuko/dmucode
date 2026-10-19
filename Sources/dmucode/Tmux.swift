import Foundation

struct TmuxSession: Identifiable, Equatable {
    /// tmux's session id, e.g. "$3". Stable across renames, unlike the name.
    let id: String
    let name: String
    /// In tmux's order (by window index).
    var windows: [TmuxWindow]
    let attachedClients: Int
}

/// A tmux window, shown as a tab above the terminal.
struct TmuxWindow: Identifiable, Equatable {
    /// tmux's window id, e.g. "@7". A window linked into several sessions
    /// has the same id in each, so target it together with the session.
    let id: String
    let index: Int
    let name: String
    /// The session's current window.
    var isActive: Bool
    /// The working directory of the window's active pane.
    let path: String
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

    // The sidebar and tab bar query, shared by the CLI and the control-mode
    // client. Names go last so they may contain spaces, and window fields
    // are tab-separated because paths may too; control clients (our own
    // `tmux -C`) are not counted as attached.
    static let listSessionsArgs = ["list-sessions", "-F", "#{session_id} #{session_name}"]
    static let listWindowsArgs = ["list-windows", "-a", "-F",
                                  "#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}\t#{pane_current_path}\t#{window_name}"]
    static let listClientsArgs = ["list-clients", "-F", "#{session_id} #{client_control_mode}"]

    static func parseSessions(sessions: [String], windows: [String], clients: [String]) -> [TmuxSession] {
        var attached: [String: Int] = [:]
        for line in clients {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[1] == "0" { attached[String(fields[0]), default: 0] += 1 }
        }
        var windowsBySession: [String: [TmuxWindow]] = [:]
        for line in windows {
            let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let index = Int(fields[2]) else { continue }
            windowsBySession[String(fields[0]), default: []].append(TmuxWindow(
                id: String(fields[1]), index: index, name: String(fields[5]), isActive: fields[3] == "1",
                path: String(fields[4])))
        }
        return sessions.compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            let id = String(fields[0])
            return TmuxSession(
                id: id,
                name: String(fields[1]),
                windows: windowsBySession[id] ?? [],
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
        let windows = try run(Self.listWindowsArgs)
        let clients = try run(Self.listClientsArgs)
        return Self.parseSessions(
            sessions: sessions.stdout.split(separator: "\n").map(String.init),
            windows: windows.stdout.split(separator: "\n").map(String.init),
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

    // Windows are targeted as "$session:@window": a window linked into
    // several sessions has one id, and the session decides which one changes.

    func selectWindow(sessionID: String, windowID: String) throws {
        let result = try run(["select-window", "-t", sessionID + ":" + windowID])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    /// Opens a new window after the session's last one, in the current
    /// window's directory, and makes it current.
    func newWindow(sessionID: String) throws {
        let result = try run(["new-window", "-a", "-t", sessionID + ":{end}", "-c", "#{pane_current_path}"])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    func renameWindow(sessionID: String, windowID: String, to name: String) throws {
        let result = try run(["rename-window", "-t", sessionID + ":" + windowID, name])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    func killWindow(sessionID: String, windowID: String) throws {
        let result = try run(["kill-window", "-t", sessionID + ":" + windowID])
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
