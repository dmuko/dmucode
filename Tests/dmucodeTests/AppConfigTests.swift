import Foundation
import Testing
@testable import dmucodeCore

struct AppConfigTests {
    @Test func parsesKeybindsAndSkipsCommentsAndBlanks() {
        let config = AppConfig.parse("""
        # dmucode
        keybind = cmd+shift+k=switch_session

        keybind=ctrl+alt+Right = next_tab
        keybind = cmd+k=unbind
        """)
        #expect(config.errors == [])
        #expect(config.keybinds == [
            Keybind(trigger: KeyTrigger([.command, .shift], "k"), action: .switchSession),
            Keybind(trigger: KeyTrigger([.control, .option], .right), action: .nextTab),
            Keybind(trigger: KeyTrigger(.command, "k"), action: nil),
        ])
    }

    @Test func badLinesAreReportedAndTheRestApplies() {
        let config = AppConfig.parse("""
        keybind = cmd+n=new_session
        font-size = 12
        keybind = cmd+x=fly
        keybind = hyper+x=quit
        keybind = cmd+bogus=quit
        keybind = k=quit
        keybind = up=quit
        just words
        keybind = =quit
        keybind = cmd+t=goto_tab:12
        """)
        #expect(config.keybinds == [Keybind(trigger: KeyTrigger(.command, "n"), action: .newSession)])
        #expect(config.errors == [
            "line 2: unknown option: font-size",
            "line 3: unknown action: fly",
            "line 4: unknown modifier: hyper",
            "line 5: unknown key: bogus",
            "line 6: k needs a modifier (cmd, ctrl, alt or shift)",
            "line 7: up needs a modifier (cmd, ctrl, alt or shift)",
            "line 8: expected `key = value`: just words",
            "line 9: expected `trigger=action`: =quit",
            "line 10: unknown action: goto_tab:12",
        ])
    }

    @Test func triggerSpellings() throws {
        func trigger(_ text: String) throws -> KeyTrigger { try KeyTrigger.parse(text).get() }
        #expect(try trigger("Cmd+Shift+K") == KeyTrigger([.command, .shift], "k"))
        #expect(try trigger("super+option+ctrl+f") == KeyTrigger([.command, .option, .control], "f"))
        #expect(try trigger("cmd+:") == KeyTrigger(.command, ":"))
        #expect(try trigger("cmd+colon") == KeyTrigger(.command, ":"))
        #expect(try trigger("cmd++") == KeyTrigger(.command, "+"))
        #expect(try trigger("cmd+plus") == KeyTrigger(.command, "+"))
        #expect(try trigger("cmd+=") == KeyTrigger(.command, "="))
        #expect(try trigger("alt+enter") == KeyTrigger(.option, .return))
        #expect(try trigger("ctrl+page_up") == KeyTrigger(.control, .pageUp))
        #expect(try trigger("f5") == KeyTrigger([], .f5))
        #expect(try trigger("cmd+1") == KeyTrigger(.command, "1"))
        #expect(KeyTrigger([.command, .shift, .control, .option], .up).description == "ctrl+alt+shift+cmd+up")
    }

    @Test func actionNamesRoundTrip() {
        for action in KeybindAction.all {
            #expect(KeybindAction(name: action.name) == action)
        }
        #expect(KeybindAction(name: "goto_session:0") == nil)
        #expect(KeybindAction(name: "goto_session:x") == nil)
        #expect(KeybindAction(name: "goto_window:1") == nil)
        #expect(KeybindAction.defaults.count == KeybindAction.all.count - 1) // kill_session has none
        #expect(KeybindAction.defaults[.killSession] == nil)
    }

    @Test func aKeybindTakesTheTriggerFromItsPreviousOwner() {
        let config = AppConfig.parse("keybind = cmd+k=new_session")
        let bindings = config.keybindings
        #expect(bindings[.newSession] == KeyTrigger(.command, "k"))
        #expect(bindings[.switchSession] == nil)
        #expect(bindings[.quit] == KeyTrigger(.command, "q"))
    }

    @Test func rebindingMovesAnActionAndFreesItsDefault() {
        let bindings = AppConfig.parse("keybind = cmd+shift+k=switch_session").keybindings
        #expect(bindings[.switchSession] == KeyTrigger([.command, .shift], "k"))
        #expect(!bindings.values.contains(KeyTrigger(.command, "k")))
    }

    @Test func unbindFreesATrigger() {
        let bindings = AppConfig.parse("keybind = cmd+k=unbind").keybindings
        #expect(bindings[.switchSession] == nil)
        #expect(bindings.count == KeybindAction.defaults.count - 1)
        // Unbinding a free trigger is fine.
        #expect(AppConfig.parse("keybind = cmd+shift+z=unbind").keybindings == KeybindAction.defaults)
    }

    @Test func laterLinesWin() {
        let bindings = AppConfig.parse("""
        keybind = cmd+j=next_session
        keybind = cmd+j=previous_session
        """).keybindings
        #expect(bindings[.previousSession] == KeyTrigger(.command, "j"))
        #expect(bindings[.nextSession] == nil)
    }

    @Test func noConfigIsTheDefaults() {
        #expect(AppConfig.load(path: "/nonexistent/dmucode/config") == AppConfig())
        #expect(AppConfig().keybindings == KeybindAction.defaults)
    }

    @Test func pathFollowsXDGAndTheOverride() {
        #expect(AppConfig.path(environment: [:], home: "/Users/alice") == "/Users/alice/.config/dmucode/config")
        #expect(AppConfig.path(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/alice") == "/xdg/dmucode/config")
        #expect(AppConfig.path(environment: ["XDG_CONFIG_HOME": ""], home: "/Users/alice") == "/Users/alice/.config/dmucode/config")
        #expect(AppConfig.path(environment: ["DMUCODE_CONFIG": "/etc/dmucode.conf"], home: "/Users/alice") == "/etc/dmucode.conf")
        #expect(AppConfig.directory(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/alice") == "/xdg/dmucode")
    }

    @Test func loadsAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmucode-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        try "keybind = cmd+shift+n=new_session\n".write(to: file, atomically: true, encoding: .utf8)
        let config = AppConfig.load(path: file.path)
        #expect(config.keybinds == [Keybind(trigger: KeyTrigger([.command, .shift], "n"), action: .newSession)])
    }
}
