import Foundation
import Testing
@testable import dmucodeCore

struct ExecutableLookupTests {
    /// A lookup over a fake filesystem that contains only `files`.
    private func lookup(
        files: Set<String> = [], path: String? = nil, user: String? = "alice", home: String = "/Users/alice"
    ) -> ExecutableLookup {
        var env: [String: String] = [:]
        env["PATH"] = path
        env["USER"] = user
        return ExecutableLookup(environment: env, home: home, isExecutable: { files.contains($0) })
    }

    @Test func searchOrder() {
        let candidates = lookup().candidates(for: "tmux")
        #expect(candidates.prefix(8) == [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/Users/alice/.nix-profile/bin/tmux",
            "/etc/profiles/per-user/alice/bin/tmux",
            "/run/current-system/sw/bin/tmux",
            "/nix/var/nix/profiles/default/bin/tmux",
            "/usr/bin/tmux",
        ])
    }

    @Test func findsMacPortsAndNix() {
        #expect(lookup(files: ["/opt/local/bin/tmux"]).find("tmux") == "/opt/local/bin/tmux")
        #expect(lookup(files: ["/Users/alice/.nix-profile/bin/tmux"]).find("tmux") == "/Users/alice/.nix-profile/bin/tmux")
        #expect(lookup(files: ["/etc/profiles/per-user/alice/bin/git"]).find("git") == "/etc/profiles/per-user/alice/bin/git")
        #expect(lookup(files: ["/run/current-system/sw/bin/tmux"]).find("tmux") == "/run/current-system/sw/bin/tmux")
        #expect(lookup(files: ["/nix/var/nix/profiles/default/bin/tmux"]).find("tmux")
            == "/nix/var/nix/profiles/default/bin/tmux")
    }

    @Test func earlierDirectoriesWin() {
        let files: Set = ["/usr/bin/git", "/opt/local/bin/git", "/opt/homebrew/bin/git"]
        #expect(lookup(files: files).find("git") == "/opt/homebrew/bin/git")
        #expect(lookup(files: ["/usr/bin/git", "/opt/local/bin/git"]).find("git") == "/opt/local/bin/git")
    }

    @Test func overrideComesFirstButMustExist() {
        let files: Set = ["/opt/homebrew/bin/tmux", "/custom/tmux"]
        #expect(lookup(files: files).find("tmux", override: "/custom/tmux") == "/custom/tmux")
        // A stale override falls through to the search.
        #expect(lookup(files: files).find("tmux", override: "/gone/tmux") == "/opt/homebrew/bin/tmux")
        #expect(lookup(files: files).find("tmux", override: "") == "/opt/homebrew/bin/tmux")
    }

    @Test func searchesPathAfterKnownDirectories() {
        let env = lookup(files: ["/opt/tools/bin/tmux"], path: "/opt/tools/bin:relative/bin:/usr/bin")
        #expect(env.find("tmux") == "/opt/tools/bin/tmux")
        let candidates = env.candidates(for: "tmux")
        #expect(candidates.last == "/opt/tools/bin/tmux")
        // Relative entries are not searched, and /usr/bin is not listed twice.
        #expect(!candidates.contains { $0.hasPrefix("relative") })
        #expect(candidates.filter { $0 == "/usr/bin/tmux" }.count == 1)
    }

    @Test func notFound() {
        #expect(lookup().find("tmux") == nil)
    }

    @Test func pathIncludesFoundDirectoryFirstWithoutDuplicates() {
        let path = lookup().path(including: "/opt/local/bin/tmux", current: "/usr/bin:/opt/homebrew/bin:/bin")
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.first == "/opt/local/bin")
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.contains("/Users/alice/.nix-profile/bin"))
        #expect(Set(parts).count == parts.count)
        // The user's own PATH entries are kept, in order.
        #expect(parts.filter { ["/usr/bin", "/bin"].contains($0) } == ["/usr/bin", "/bin"])
    }

    @Test func pathWithoutCurrentFallsBackToSystemDirectories() {
        let parts = lookup().path(including: nil, current: nil).split(separator: ":").map(String.init)
        #expect(parts.suffix(4) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }

    @Test func tmuxResolveUsesTheLookup() {
        let lookup = lookup(files: ["/opt/local/bin/tmux"])
        let tmux = Tmux.resolve(lookup: lookup, environment: ["DMUCODE_TMUX_SOCKET": "test"])
        #expect(tmux?.executable == "/opt/local/bin/tmux")
        #expect(tmux?.socketName == "test")
        #expect(Tmux.resolve(lookup: self.lookup(), environment: [:]) == nil)
        #expect(Tmux.resolve(lookup: lookup, environment: ["DMUCODE_TMUX": "/custom/tmux"])?.executable
            == "/opt/local/bin/tmux")
    }

    @Test func tmuxEnvironmentPathStartsWithItsDirectory() {
        let tmux = Tmux(executable: "/opt/local/bin/tmux", socketName: nil)
        #expect(tmux.environment["PATH"]?.hasPrefix("/opt/local/bin:") == true)
    }

    // MARK: Login shell output

    @Test func shellOutputTakesTheLastExecutablePath() {
        let exists: (String) -> Bool = { $0 == "/nix/store/x/bin/tmux" }
        let banner = "Welcome back!\nLast login: Mon\n/not/there\n/nix/store/x/bin/tmux\n"
        #expect(ExecutableLookup.parseShellOutput(banner, isExecutable: exists) == "/nix/store/x/bin/tmux")
        #expect(ExecutableLookup.parseShellOutput("alias tmux='x'\n", isExecutable: exists) == nil)
        #expect(ExecutableLookup.parseShellOutput("", isExecutable: exists) == nil)
    }

    // The shells below are throwaway scripts in a temporary directory.

    private func fakeShell(_ body: String) throws -> (directory: URL, shell: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmucode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shell = directory.appendingPathComponent("shell")
        try ("#!/bin/sh\n" + body + "\n").write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        return (directory, shell.path)
    }

    @Test func loginShellFallbackSkipsBanners() throws {
        let (directory, shell) = try fakeShell("echo 'Welcome!'; echo /bin/sh")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lookup = ExecutableLookup(environment: [:], home: "/h")
        #expect(lookup.findViaLoginShell("tmux", shell: shell, timeout: 10) == "/bin/sh")
    }

    @Test func loginShellFallbackGivesUpOnAHungShell() throws {
        let (directory, shell) = try fakeShell("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lookup = ExecutableLookup(environment: [:], home: "/h")
        let start = ContinuousClock.now
        #expect(lookup.findViaLoginShell("tmux", shell: shell, timeout: 0.3) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func loginShellFallbackIgnoresAFailingOrMissingShell() throws {
        let (directory, shell) = try fakeShell("echo /bin/sh; exit 1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lookup = ExecutableLookup(environment: [:], home: "/h")
        #expect(lookup.findViaLoginShell("tmux", shell: shell, timeout: 10) == nil)
        // The injected check says the shell doesn't exist.
        let none = ExecutableLookup(environment: [:], home: "/h", isExecutable: { _ in false })
        #expect(none.findViaLoginShell("tmux", shell: shell, timeout: 10) == nil)
    }
}
