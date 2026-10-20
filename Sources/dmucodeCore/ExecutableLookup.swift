import Foundation

/// Finds command-line tools (tmux, git) by absolute path. Apps started from
/// Finder don't inherit the shell's PATH, so the usual install locations are
/// tried by hand. The filesystem check is injectable for tests.
public struct ExecutableLookup {
    private let environment: [String: String]
    private let home: String
    private let isExecutable: (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.home = home
        self.isExecutable = isExecutable
    }

    /// The directories searched, in order: Homebrew (Apple silicon, then
    /// Intel), MacPorts, Nix (user profile, nix-darwin / NixOS-style per-user
    /// profile, system profile, default profile), then the system's.
    var knownDirectories: [String] {
        let user = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            home + "/.nix-profile/bin",
            "/etc/profiles/per-user/\(user)/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
            "/usr/bin",
        ]
    }

    /// Absolute directories of the process's own PATH.
    private var pathDirectories: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    /// Every path tried for `name`, in order: `override`, the known
    /// directories, then the directories of PATH (set when started from a
    /// terminal).
    func candidates(for name: String, override: String? = nil) -> [String] {
        var seen = Set<String>()
        let overridePath = override.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        return (overridePath + (knownDirectories + pathDirectories).map { $0 + "/" + name })
            .filter { seen.insert($0).inserted }
    }

    /// The first candidate that is executable. An `override` that doesn't
    /// exist is skipped rather than being an error.
    public func find(_ name: String, override: String? = nil) -> String? {
        candidates(for: name, override: override).first(where: isExecutable)
    }

    /// A PATH for processes the app starts: the directory of the tool that
    /// was found, the known third-party locations, then `current`. A tmux
    /// server started by the app keeps this PATH for its panes.
    func path(including executable: String?, current: String?) -> String {
        let found = executable.map { ($0 as NSString).deletingLastPathComponent }
        let known = knownDirectories.filter { $0 != "/usr/bin" }
        let rest = (current ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return ((found.map { [$0] } ?? []) + known + rest)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    // MARK: Login shell

    /// Last resort: asks the user's login shell where `name` is, for installs
    /// outside the usual directories whose PATH is set up in the shell's
    /// profile. Blocks for up to `timeout` seconds, so call it off the main
    /// thread.
    public func findViaLoginShell(_ name: String, timeout: TimeInterval = 3) -> String? {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
            ?? "/bin/zsh"
        return findViaLoginShell(name, shell: shell, timeout: timeout)
    }

    func findViaLoginShell(_ name: String, shell: String, timeout: TimeInterval) -> String? {
        guard isExecutable(shell),
              let output = Self.run(shell: shell, arguments: ["-l", "-c", "command -v " + name], timeout: timeout)
        else { return nil }
        return Self.parseShellOutput(output, isExecutable: isExecutable)
    }

    /// Profiles may print banners, so take the last line that is an absolute
    /// path to an executable. Aliases and functions (`alias tmux=...`) are
    /// not paths and are skipped.
    static func parseShellOutput(_ output: String, isExecutable: (String) -> Bool) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && isExecutable($0) }
    }

    /// Runs the shell with no stdin, discarding stderr; nil on failure or when
    /// it hasn't finished (output included) within `timeout`, in which case
    /// it is terminated.
    private static func run(shell: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // Read on another thread: a hung shell must not block us, and a
        // killed one closes the pipe, which ends the read.
        let box = OutputBox()
        let read = DispatchSemaphore(value: 0)
        // A thread of its own: the read blocks, and a dispatch queue might
        // have no free worker for it (see Tmux.run).
        Thread {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }.start()

        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success, read.wait(timeout: deadline) == .success else {
            process.terminate()
            // A shell that ignores SIGTERM gets SIGKILL.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}
