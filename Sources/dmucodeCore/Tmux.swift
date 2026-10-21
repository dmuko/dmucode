import Foundation

public struct TmuxSession: Identifiable, Equatable {
    /// tmux's session id, e.g. "$3". Stable across renames, unlike the name.
    public let id: String
    public let name: String
    /// In tmux's order (by window index).
    public var windows: [TmuxWindow]
    public let attachedClients: Int

    public var hasBell: Bool { windows.contains { $0.hasBell } }
    public var hasActivity: Bool { windows.contains { $0.hasActivity } }
}

/// A tmux window, shown as a tab above the terminal.
public struct TmuxWindow: Identifiable, Equatable {
    /// tmux's window id, e.g. "@7". A window linked into several sessions
    /// has the same id in each, so target it together with the session.
    public let id: String
    public let index: Int
    public let name: String
    /// The session's current window.
    public var isActive: Bool
    /// The working directory of the window's active pane.
    public let path: String
    /// tmux's alert flags: a bell rang, or (with monitor-activity) there was
    /// output, since the window was last current. tmux doesn't set them for
    /// the current window of an attached session.
    public var hasBell = false
    public var hasActivity = false
}

/// A pane, for the palette's search. Fetched when the palette opens.
public struct TmuxPane: Equatable {
    /// tmux's pane id, e.g. "%5".
    public let id: String
    public let sessionID: String
    public let windowID: String
    /// The active pane of its window.
    public let isActive: Bool
    let command: String
    let path: String
    /// Set by the program in the pane (OSC 2): Claude Code puts its topic
    /// there, nvim its command line, shells often the directory.
    let title: String
    /// The title is still tmux's default, the host name.
    let hasDefaultTitle: Bool

    private static let shells: Set<String> = ["fish", "zsh", "bash", "sh", "dash", "tcsh", "nu"]

    /// The title when it says more than the host name or a directory.
    public var meaningfulTitle: String? {
        let title = self.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !hasDefaultTitle, !title.hasPrefix("~"), !title.hasPrefix("/"),
              title != command else { return nil }
        return title
    }

    /// The program, unless it is just the shell.
    public var meaningfulCommand: String? {
        Self.shells.contains(command) || command.isEmpty ? nil : command
    }
}

/// A tmux command, offered as a completion in the command bar.
public struct TmuxCommand {
    public let name: String
    public let alias: String
    public let usage: String
}

public struct TmuxError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Thin wrapper over the tmux CLI. Calls block, so run them off the main thread.
public struct Tmux {
    /// Absolute path: apps started from Finder don't inherit the shell's PATH.
    public let executable: String
    /// `-L` socket name from DMUCODE_TMUX_SOCKET; nil means the default server.
    public let socketName: String?

    /// Looks for tmux in DMUCODE_TMUX, then the usual install locations (see
    /// `ExecutableLookup`). Fast; see `resolveViaLoginShell` for the fallback.
    public static func resolve(
        lookup: ExecutableLookup = ExecutableLookup(),
        environment env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Tmux? {
        lookup.find("tmux", override: env["DMUCODE_TMUX"]).map { make(executable: $0, environment: env) }
    }

    /// For when `resolve` finds nothing: asks the user's login shell where
    /// tmux is (its profile may put it on PATH somewhere unusual). Runs off
    /// the main thread, with a short timeout; `completion` runs on the main
    /// thread with nil if the shell doesn't know either.
    public static func resolveViaLoginShell(
        lookup: ExecutableLookup = ExecutableLookup(),
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        completion: @escaping @Sendable (Tmux?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tmux = lookup.findViaLoginShell("tmux").map { make(executable: $0, environment: env) }
            DispatchQueue.main.async { completion(tmux) }
        }
    }

    private static func make(executable: String, environment env: [String: String]) -> Tmux {
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
                                  "#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}#{window_bell_flag}#{window_activity_flag}\t#{pane_current_path}\t#{window_name}"]
    static let listClientsArgs = ["list-clients", "-F", "#{session_id} #{client_control_mode}"]
    /// Flags: pane_active, and whether the title is the host name (tmux's
    /// default). The title goes last: programs put anything in it.
    static let listPanesArgs = ["list-panes", "-a", "-F",
                                "#{session_id}\t#{window_id}\t#{pane_id}\t#{pane_active}"
                                    + "#{||:#{==:#{pane_title},#{host}},#{==:#{pane_title},#{host_short}}}"
                                    + "\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}"]

    static func parsePanes(_ lines: [String]) -> [TmuxPane] {
        lines.compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
            let flags = Array(fields.count == 7 ? fields[3] : "")
            guard fields.count == 7, flags.count == 2 else { return nil }
            return TmuxPane(
                id: String(fields[2]), sessionID: String(fields[0]), windowID: String(fields[1]),
                isActive: flags[0] == "1", command: String(fields[4]), path: String(fields[5]),
                title: String(fields[6]), hasDefaultTitle: flags[1] == "1")
        }
    }

    static func parseSessions(sessions: [String], windows: [String], clients: [String]) -> [TmuxSession] {
        var attached: [String: Int] = [:]
        for line in clients {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[1] == "0" { attached[String(fields[0]), default: 0] += 1 }
        }
        var windowsBySession: [String: [TmuxWindow]] = [:]
        for line in windows {
            let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            // Flags: window_active, window_bell_flag, window_activity_flag.
            let flags = Array(fields.count == 6 ? fields[3] : "")
            guard fields.count == 6, flags.count == 3, let index = Int(fields[2]) else { continue }
            windowsBySession[String(fields[0]), default: []].append(TmuxWindow(
                id: String(fields[1]), index: index, name: String(fields[5]), isActive: flags[0] == "1",
                path: String(fields[4]), hasBell: flags[1] == "1", hasActivity: flags[2] == "1"))
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
    public func newSession(name: String?, directory: String) throws -> String {
        var args = ["new-session", "-d", "-P", "-F", "#{session_id}", "-c", directory]
        if let name, !name.isEmpty { args += ["-s", name] }
        let result = try run(args)
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func renameSession(id: String, to name: String) throws {
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

    public func killSession(id: String) throws {
        let result = try run(["kill-session", "-t", id])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    // Windows are targeted as "$session:@window": a window linked into
    // several sessions has one id, and the session decides which one changes.

    func selectWindow(sessionID: String, windowID: String) throws {
        let result = try run(["select-window", "-t", sessionID + ":" + windowID])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    func selectPane(id: String) throws {
        let result = try run(["select-pane", "-t", id])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    func listPanes() throws -> [TmuxPane] {
        let result = try run(Self.listPanesArgs)
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
        return Self.parsePanes(result.stdout.split(separator: "\n").map(String.init))
    }

    /// Opens a new window after the session's last one, in the current
    /// window's directory, and makes it current.
    public func newWindow(sessionID: String) throws {
        let result = try run(["new-window", "-a", "-t", sessionID + ":{end}", "-c", "#{pane_current_path}"])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    public func renameWindow(sessionID: String, windowID: String, to name: String) throws {
        let result = try run(["rename-window", "-t", sessionID + ":" + windowID, name])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    public func killWindow(sessionID: String, windowID: String) throws {
        let result = try run(["kill-window", "-t", sessionID + ":" + windowID])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
    }

    // MARK: Command bar

    /// tmux's commands with their aliases and usage, for completion.
    func listCommands() throws -> [TmuxCommand] {
        let result = try run(["list-commands", "-F", "#{command_list_name}\t#{command_list_alias}\t#{command_list_usage}"])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return TmuxCommand(name: String(fields[0]), alias: String(fields[1]), usage: String(fields[2]))
        }
    }

    /// The active pane of the session's current window: what its terminal shows.
    func activePane(sessionID: String) throws -> String {
        let result = try run(["display-message", "-p", "-t", sessionID, "#{pane_id}"])
        guard result.status == 0 else { throw TmuxError(description: result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a line typed into the command bar, parsed by tmux like its own
    /// `:` prompt. With TMUX_PANE set, tmux treats that pane as current, so
    /// commands without -t act on what the terminal shows; commands that need
    /// a client (detach-client, switch-client) get the terminal's client, as
    /// tmux picks one attached to that session. Returns the output
    /// (e.g. of display -p or list-*); errors are thrown with tmux's message.
    func runCommandLine(_ line: String, pane: String) throws -> String {
        var env = environment
        env["TMUX_PANE"] = pane
        let result = try run(["source-file", "-"], input: line + "\n", environment: env)
        guard result.status == 0 else {
            // source-file reports parse and command errors on stdout:
            // "-:1: unknown command: foo" -> "unknown command: foo"
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
            throw TmuxError(description: message.replacingOccurrences(of: #"^-:\d+: "#, with: "", options: .regularExpression))
        }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    /// The shell command a terminal surface runs to show a session.
    public func attachCommand(sessionID: String) -> String {
        ([executable] + globalArgs + ["attach-session", "-t", sessionID])
            .map(Self.shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The environment for tmux processes started by the app. A tmux server
    /// started from here inherits it, so give it a usable PATH even when the
    /// app was launched from Finder: the directory tmux was found in, so the
    /// server finds the same tools, and the other usual install locations.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ExecutableLookup(environment: env).path(including: executable, current: env["PATH"])
        // tmux configs often set default-terminal to xterm-ghostty, which
        // panes can only resolve if the server knows where its terminfo is.
        if env["TERMINFO"] == nil, let terminfo = Bundle.main.resourceURL?.appendingPathComponent("terminfo").path,
           FileManager.default.fileExists(atPath: terminfo) {
            env["TERMINFO"] = terminfo
        }
        return env
    }

    private func run(
        _ args: [String], input: String? = nil, environment: [String: String]? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let output = try Subprocess.run(
            executable: executable, arguments: globalArgs + args, input: input,
            environment: environment ?? self.environment)
        return (output.status, output.stdout, output.stderr)
    }

    /// The path of the server's socket, as tmux computes it from `-L`:
    /// `$TMUX_TMPDIR` (or /tmp) + `tmux-<uid>/<socket name>`. Used to point
    /// other tools (sesh) at the same server through the TMUX variable.
    public var socketPath: String {
        Self.socketPath(socketName: socketName, environment: ProcessInfo.processInfo.environment, uid: getuid())
    }

    static func socketPath(socketName: String?, environment: [String: String], uid: uid_t) -> String {
        var base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return base + "/tmux-\(uid)/" + (socketName ?? "default")
    }
}
