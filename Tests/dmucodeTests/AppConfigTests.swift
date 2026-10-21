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

    @Test func parsesTheChromeOptions() {
        let config = AppConfig.parse("""
        title-bar = false
        tabs = Auto
        tab-git-status = off
        sidebar-window-count = no
        sidebar-shortcuts = 0
        full-disk-access-prompt = n
        desktop-notifications = false
        """)
        #expect(config.errors == [])
        #expect(!config.titleBar)
        #expect(config.tabs == .auto)
        #expect(!config.tabGitStatus)
        #expect(!config.sidebarWindowCount)
        #expect(!config.sidebarShortcuts)
        #expect(!config.fullDiskAccessPrompt)
        #expect(!config.desktopNotifications)
        #expect(config.settingsDescription
            == "title-bar=false,tabs=auto,tab-git-status=false,sidebar-window-count=false,sidebar-shortcuts=false,"
            + "full-disk-access-prompt=false,desktop-notifications=false")
    }

    @Test func chromeOptionsDefaultToOnAndTheLastValueWins() {
        let defaults = AppConfig()
        #expect(defaults.titleBar && defaults.tabGitStatus && defaults.sidebarWindowCount && defaults.sidebarShortcuts)
        #expect(defaults.fullDiskAccessPrompt && defaults.desktopNotifications)
        #expect(defaults.tabs == .always)
        let config = AppConfig.parse("tabs = never\ntabs = always\ntitle-bar = false\ntitle-bar = true")
        #expect(config.tabs == .always)
        #expect(config.titleBar)
    }

    @Test func badChromeValuesAreReported() {
        let config = AppConfig.parse("""
        title-bar = maybe
        tabs = sometimes
        """)
        #expect(config.titleBar)
        #expect(config.tabs == .always)
        #expect(config.errors == [
            "line 1: title-bar must be true or false: maybe",
            "line 2: tabs must be always, auto or never: sometimes",
        ])
    }

    @Test func boolSpellings() {
        for text in ["true", "True", "yes", "on", "1", "t", "y"] { #expect(AppConfig.parseBool(text) == true, "\(text)") }
        for text in ["false", "FALSE", "no", "off", "0", "f", "n"] { #expect(AppConfig.parseBool(text) == false, "\(text)") }
        #expect(AppConfig.parseBool("") == nil)
        #expect(AppConfig.parseBool("enabled") == nil)
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

struct ConfigExampleTests {
    /// docs/config.example lists every option as a comment; uncommented,
    /// each line must parse, and the keybind lines must restate the
    /// defaults (the example is what users copy).
    @Test func exampleParsesAndMatchesTheDefaults() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/config.example")
        let text = try String(contentsOf: url, encoding: .utf8)
        // "# keybind = cmd+k=switch_session   # palette…" -> "keybind = cmd+k=switch_session"
        let pattern = #"^# ((?:keybind|title-bar|tabs|tab-git-status|sidebar-window-count|sidebar-shortcuts|full-disk-access-prompt|desktop-notifications) = .*?)(?:\s{2,}#.*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var lines: [String] = []
        for line in text.split(separator: "\n") {
            let line = String(line)
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                lines.append(String(line[range]))
            }
        }
        #expect(lines.count > 30)
        let config = AppConfig.parse(lines.joined(separator: "\n"))
        #expect(config.errors == [])
        // The chrome options as written are the defaults.
        var chrome = config
        chrome.keybinds = []
        #expect(chrome == AppConfig())
        // The default keybind lines (before the examples) restate every default.
        let defaultsSection = text.components(separatedBy: "# Examples:")[0]
        let defaultLines = defaultsSection.split(separator: "\n").compactMap { line -> String? in
            let line = String(line)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), line.contains("keybind") else { return nil }
            return String(line[range])
        }
        let restated = AppConfig.parse(defaultLines.joined(separator: "\n"))
        #expect(restated.errors == [])
        for keybind in restated.keybinds {
            let action = try #require(keybind.action)
            #expect(KeybindAction.defaults[action] == keybind.trigger, Comment(rawValue: action.name))
        }
        #expect(restated.keybinds.count == KeybindAction.defaults.count - 16) // goto_session/goto_tab 2…9 are "…"
    }
}
