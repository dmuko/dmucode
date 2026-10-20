import Foundation

/// A session that isn't running yet but could be started from a template:
/// an entry of sesh's config (`sesh list --config --json`).
public struct SessionTemplate: Equatable, Decodable {
    /// The tmux session's name once started, e.g. "Projects/dmucode".
    public let name: String
    /// The session's working directory, absolute (sesh expands "~").
    public let path: String
    /// What sesh types into the new session, e.g. "claude"; may be empty.
    public let startupCommand: String

    public init(name: String, path: String, startupCommand: String = "") {
        self.name = name
        self.path = path
        self.startupCommand = startupCommand
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case path = "Path"
        case startupCommand = "StartupCommand"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
    }
}

/// Where session templates come from and how one is started. `Sesh` is the
/// real one; tests use a fake. Blocking calls; the store makes them off the
/// main thread.
public protocol SessionTemplates {
    func list() throws -> [SessionTemplate]
    /// Starts the template's session on the store's tmux server. With
    /// `pane`, the client showing that pane is switched to the new session,
    /// as `sesh connect` does inside tmux.
    func start(_ name: String, pane: String?) throws
}

/// [sesh](https://github.com/joshmedeski/sesh) as a source of session
/// templates. Listing and starting are left to sesh itself, so its config
/// (paths, startup commands, windows, tmuxinator...) applies as in the shell.
public struct Sesh: SessionTemplates {
    /// Absolute path; see `ExecutableLookup`.
    let executable: String
    let tmux: Tmux

    /// Looks for sesh in DMUCODE_SESH, then the usual install locations.
    /// Nil, and the app behaves as before, when it isn't installed.
    public static func resolve(
        tmux: Tmux,
        lookup: ExecutableLookup = ExecutableLookup(),
        environment env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Sesh? {
        lookup.find("sesh", override: env["DMUCODE_SESH"]).map { Sesh(executable: $0, tmux: tmux) }
    }

    public func list() throws -> [SessionTemplate] {
        let result = try run(["list", "--config", "--json"], pane: nil)
        guard result.status == 0 else { throw SeshError(description: Self.message(result)) }
        return try Self.parseList(Data(result.stdout.utf8))
    }

    /// Entries without a name can't become sessions and are dropped. sesh
    /// prints "null" when nothing is configured.
    static func parseList(_ data: Data) throws -> [SessionTemplate] {
        let entries = try JSONDecoder().decode([SessionTemplate]?.self, from: data) ?? []
        return entries.filter { !$0.name.isEmpty }
    }

    /// `sesh connect <name>`, which creates the session on the server named
    /// by TMUX (see `environment`), sends the startup command, and switches
    /// the client of TMUX_PANE to it. Without a client to switch, sesh
    /// reports a failure although the session was created, so the caller
    /// checks for the session rather than trusting the status.
    public func start(_ name: String, pane: String?) throws {
        let result = try run(["connect", name], pane: pane)
        guard result.status == 0 else { throw SeshError(description: Self.message(result)) }
    }

    /// The environment sesh runs in. TMUX names the socket, which both makes
    /// sesh's tmux calls go to the app's server (tmux reads the socket path
    /// from TMUX when there is no -L or -S) and makes sesh behave as inside
    /// tmux: switch-client instead of attach, which has no terminal here.
    /// The pid and session fields of TMUX aren't used by either. PATH is
    /// tmux's, so sesh finds the same tmux (and tmux's TERMINFO applies).
    func environment(pane: String?) -> [String: String] {
        var env = tmux.environment
        env["TMUX"] = tmux.socketPath + ",0,0"
        env["TMUX_PANE"] = pane
        return env
    }

    private func run(_ args: [String], pane: String?) throws -> Subprocess.Output {
        try Subprocess.run(executable: executable, arguments: args, environment: environment(pane: pane))
    }

    /// sesh prints errors with ANSI colors and a box; keep the text.
    static func message(_ result: Subprocess.Output) -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        let plain = text.replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        let lines = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "ERROR" }
        return lines.isEmpty ? "sesh failed (status \(result.status))" : lines.joined(separator: " ")
    }
}

public struct SeshError: Error, CustomStringConvertible, Equatable {
    public let description: String
}
