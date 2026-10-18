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

    private var globalArgs: [String] { socketName.map { ["-L", $0] } ?? [] }

    func listSessions() throws -> [TmuxSession] {
        let format = ["#{session_id}", "#{session_name}", "#{session_windows}", "#{session_attached}"]
            .joined(separator: "\t")
        let result = try run(["list-sessions", "-F", format])
        if result.status != 0 {
            // No server yet simply means no sessions.
            if result.stderr.contains("no server running") || result.stderr.contains("error connecting") {
                return []
            }
            throw TmuxError(description: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { return nil }
            return TmuxSession(
                id: fields[0],
                name: fields[1],
                windows: Int(fields[2]) ?? 0,
                attachedClients: Int(fields[3]) ?? 0)
        }
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

    private func run(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = globalArgs + args

        // A tmux server started from here inherits this environment, so give
        // it a usable PATH even when the app was launched from Finder.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // tmux configs often set default-terminal to xterm-ghostty, which
        // panes can only resolve if the server knows where its terminfo is.
        if env["TERMINFO"] == nil, let terminfo = Bundle.main.resourceURL?.appendingPathComponent("terminfo").path,
           FileManager.default.fileExists(atPath: terminfo) {
            env["TERMINFO"] = terminfo
        }
        process.environment = env

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
