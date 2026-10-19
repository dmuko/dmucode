import Testing
@testable import dmucode

struct TmuxParseTests {
    @Test func sessionsWithWindowsAndClients() {
        let sessions = Tmux.parseSessions(
            sessions: ["$0 main", "$1 my work"],
            windows: [
                "$0\t@0\t0\t100\t/Users/me\tzsh",
                "$0\t@1\t1\t011\t/Users/me/dir with spaces\tvim: notes.md",
                "$1\t@2\t1\t100\t/tmp\tname\twith\ttabs",
            ],
            clients: ["$0 0", "$0 1", "$1 0", "$1 0"])
        #expect(sessions == [
            TmuxSession(id: "$0", name: "main", windows: [
                TmuxWindow(id: "@0", index: 0, name: "zsh", isActive: true, path: "/Users/me"),
                TmuxWindow(id: "@1", index: 1, name: "vim: notes.md", isActive: false,
                           path: "/Users/me/dir with spaces", hasBell: true, hasActivity: true),
            ], attachedClients: 1),
            TmuxSession(id: "$1", name: "my work", windows: [
                TmuxWindow(id: "@2", index: 1, name: "name\twith\ttabs", isActive: true, path: "/tmp"),
            ], attachedClients: 2),
        ])
    }

    @Test func controlClientsAreNotAttached() {
        let sessions = Tmux.parseSessions(sessions: ["$0 main"], windows: [], clients: ["$0 1"])
        #expect(sessions.first?.attachedClients == 0)
    }

    @Test func emptyPathAndName() {
        let sessions = Tmux.parseSessions(sessions: ["$0 s"], windows: ["$0\t@0\t0\t100\t\t"], clients: [])
        #expect(sessions.first?.windows == [TmuxWindow(id: "@0", index: 0, name: "", isActive: true, path: "")])
    }

    @Test func malformedLinesAreSkipped() {
        let sessions = Tmux.parseSessions(
            sessions: ["$0 ok", "no-name", ""],
            windows: [
                "$0\t@0\tx\t100\t/\tbad index",
                "$0\t@1\t1\t10\t/\tshort flags",
                "$0\t@2\t2\t100\ttoo few fields",
                "$0\t@3\t3\t000\t/\tgood",
            ],
            clients: ["$0", "garbage line here"])
        #expect(sessions == [
            TmuxSession(id: "$0", name: "ok", windows: [
                TmuxWindow(id: "@3", index: 3, name: "good", isActive: false, path: "/"),
            ], attachedClients: 0),
        ])
    }

    @Test func windowsOfUnknownSessionsAreDropped() {
        let sessions = Tmux.parseSessions(sessions: ["$1 a"], windows: ["$9\t@0\t0\t100\t/\tw"], clients: [])
        #expect(sessions.first?.windows == [])
    }
}
