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

    // MARK: Panes

    @Test func panes() {
        let panes = Tmux.parsePanes([
            "$0\t@1\t%5\t10\tclaude\t/Users/me/code\t✳ Fix the login bug",
            "$0\t@1\t%6\t01\tfish\t/Users/me\texample-mac.local",
            "$1\t@2\t%7\t10\tnvim\t/tmp\ttitle\twith\ttabs",
            "bad line",
            "$1\t@2\t%8\t1\tsh\t/\tshort flags",
        ])
        #expect(panes == [
            TmuxPane(id: "%5", sessionID: "$0", windowID: "@1", isActive: true, command: "claude",
                     path: "/Users/me/code", title: "✳ Fix the login bug", hasDefaultTitle: false),
            TmuxPane(id: "%6", sessionID: "$0", windowID: "@1", isActive: false, command: "fish",
                     path: "/Users/me", title: "example-mac.local", hasDefaultTitle: true),
            TmuxPane(id: "%7", sessionID: "$1", windowID: "@2", isActive: true, command: "nvim",
                     path: "/tmp", title: "title\twith\ttabs", hasDefaultTitle: false),
        ])
    }

    private func pane(title: String, command: String = "fish", defaultTitle: Bool = false) -> TmuxPane {
        TmuxPane(id: "%0", sessionID: "$0", windowID: "@0", isActive: true, command: command,
                 path: "/", title: title, hasDefaultTitle: defaultTitle)
    }

    @Test func meaningfulTitles() {
        #expect(pane(title: "✳ Fix the login bug", command: "claude").meaningfulTitle == "✳ Fix the login bug")
        #expect(pane(title: "nvim -c ':Neotree' ~/.config", command: "nvim").meaningfulTitle != nil)
        // The host name (tmux's default), a directory, the program itself, nothing.
        #expect(pane(title: "example-mac.local", defaultTitle: true).meaningfulTitle == nil)
        #expect(pane(title: "~/C/C/dmucode").meaningfulTitle == nil)
        #expect(pane(title: "/var/log").meaningfulTitle == nil)
        #expect(pane(title: "htop", command: "htop").meaningfulTitle == nil)
        #expect(pane(title: "  ").meaningfulTitle == nil)
    }

    @Test func meaningfulCommands() {
        #expect(pane(title: "", command: "claude").meaningfulCommand == "claude")
        #expect(pane(title: "", command: "fish").meaningfulCommand == nil)
        #expect(pane(title: "", command: "zsh").meaningfulCommand == nil)
        #expect(pane(title: "", command: "").meaningfulCommand == nil)
    }
}
