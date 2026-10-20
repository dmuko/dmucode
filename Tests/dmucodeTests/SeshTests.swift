import Foundation
import Testing
@testable import dmucodeCore

struct SeshTests {
    /// Two entries of `sesh list --config --json` (2.33), the fields the
    /// app reads and a few it doesn't.
    private let json = """
    [{"Src":"config","Name":"Projects/dmucode","Path":"/Users/alice/Code/dmucode/","StartupCommand":"claude",
      "PreviewCommand":"eza {}","DisableStartupCommand":false,"Tmuxinator":"","Attached":0,"Windows":0,
      "WindowConfigs":null,"Score":0,"Icon":"","Worktree":null,"LastAttached":null},
     {"Src":"config","Name":"New","Path":"/Users/alice/","StartupCommand":""},
     {"Src":"config","Name":"","Path":"/nowhere"}]
    """

    @Test func parsesTheConfiguredSessions() throws {
        let templates = try Sesh.parseList(Data(json.utf8))
        #expect(templates == [
            SessionTemplate(name: "Projects/dmucode", path: "/Users/alice/Code/dmucode/", startupCommand: "claude"),
            SessionTemplate(name: "New", path: "/Users/alice/"),
        ])
    }

    @Test func noConfigIsNoTemplates() throws {
        #expect(try Sesh.parseList(Data("null\n".utf8)) == [])
        #expect(try Sesh.parseList(Data("[]".utf8)) == [])
    }

    @Test func malformedOutputIsAnError() {
        #expect(throws: (any Error).self) { try Sesh.parseList(Data("not json".utf8)) }
    }

    @Test func errorMessageDropsSeshsDecoration() {
        let output = Subprocess.Output(
            status: 1, stdout: "",
            stderr: "\u{1B}[31m\n   ERROR  \n\n  Failed to switch to tmux session: exit status 1.  \u{1B}[0m\n")
        #expect(Sesh.message(output) == "Failed to switch to tmux session: exit status 1.")
        #expect(Sesh.message(Subprocess.Output(status: 2, stdout: "", stderr: "")) == "sesh failed (status 2)")
    }

    @Test func socketPathFollowsTmuxsRule() {
        #expect(Tmux.socketPath(socketName: nil, environment: [:], uid: 501) == "/tmp/tmux-501/default")
        #expect(Tmux.socketPath(socketName: "dev", environment: [:], uid: 501) == "/tmp/tmux-501/dev")
        #expect(Tmux.socketPath(socketName: "dev", environment: ["TMUX_TMPDIR": "/var/run/"], uid: 7)
            == "/var/run/tmux-7/dev")
        #expect(Tmux.socketPath(socketName: nil, environment: ["TMUX_TMPDIR": ""], uid: 7) == "/tmp/tmux-7/default")
    }

    /// sesh is pointed at the app's server through TMUX, which also makes it
    /// switch rather than attach, and at the shown pane through TMUX_PANE.
    @Test func environmentPointsSeshAtTheServerAndThePane() {
        let tmux = Tmux(executable: "/opt/homebrew/bin/tmux", socketName: "dev")
        let sesh = Sesh(executable: "/opt/homebrew/bin/sesh", tmux: tmux)
        let env = sesh.environment(pane: "%3")
        #expect(env["TMUX"] == tmux.socketPath + ",0,0")
        #expect(env["TMUX_PANE"] == "%3")
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
        #expect(sesh.environment(pane: nil)["TMUX_PANE"] == nil)
    }
}
