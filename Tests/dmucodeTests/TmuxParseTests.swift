import Testing
@testable import dmucodeCore

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

struct SidebarTitleTests {
    private func pane(_ id: String, session: String = "$0", window: String = "@0", active: Bool = true,
                      command: String = "fish", title: String) -> TmuxPane {
        TmuxPane(id: id, sessionID: session, windowID: window, isActive: active, command: command,
                 path: "/", title: title, hasDefaultTitle: false)
    }

    private func window(_ id: String, index: Int, active: Bool) -> TmuxWindow {
        TmuxWindow(id: id, index: index, name: "w", isActive: active, path: "/")
    }

    @Test func aLeadingStatusSymbolIsCutOff() {
        #expect(pane("%0", command: "claude", title: "✳ Sesh integration").sidebarTitle == "Sesh integration")
        #expect(pane("%0", command: "claude", title: "⠐ Working on it").sidebarTitle == "Working on it")
        #expect(pane("%0", command: "nvim", title: "nvim -c ':Neotree' ~/.config").sidebarTitle == "nvim -c ':Neotree' ~/.config")
        // A word that starts with a non-ASCII letter stays.
        #expect(pane("%0", command: "claude", title: "Ä ö").sidebarTitle == "Ä ö")
        #expect(pane("%0", command: "claude", title: "✳ ").sidebarTitle == nil)
        // Directories and the program's own name say nothing.
        #expect(pane("%0", title: "~/src/dmucode").sidebarTitle == nil)
        #expect(pane("%0", command: "htop", title: "htop").sidebarTitle == nil)
    }

    @Test func anAgentsTitleGoesFirstThenTheCurrentWindowsActivePane() {
        let sessions = [
            TmuxSession(id: "$0", name: "notes",
                        windows: [window("@1", index: 1, active: true), window("@2", index: 2, active: false)],
                        attachedClients: 0),
            TmuxSession(id: "$1", name: "config",
                        windows: [window("@3", index: 1, active: false), window("@4", index: 2, active: true)],
                        attachedClients: 0),
            TmuxSession(id: "$2", name: "shell", windows: [window("@5", index: 1, active: true)], attachedClients: 0),
        ]
        let panes = [
            // notes: nvim is the active pane, Claude Code is in a split.
            pane("%1", session: "$0", window: "@1", active: true, command: "nvim", title: "nvim  ~/D/Notes"),
            pane("%2", session: "$0", window: "@1", active: false, command: "claude", title: "✳ Notes repo"),
            pane("%3", session: "$0", window: "@2", active: true, title: "~/D/Notes"),
            // config: no agent; the current window (@4) wins over the first.
            pane("%4", session: "$1", window: "@3", active: true, command: "nvim", title: "nvim init.lua"),
            pane("%5", session: "$1", window: "@4", active: false, command: "nvim", title: "nvim other.lua"),
            pane("%6", session: "$1", window: "@4", active: true, command: "nvim", title: "nvim config"),
            // shell: only a directory.
            pane("%7", session: "$2", window: "@5", title: "~"),
        ]
        #expect(TmuxPane.sidebarTitles(of: panes, in: sessions) == ["$0": "Notes repo", "$1": "nvim config"])
    }
}

