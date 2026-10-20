import Foundation

/// dmucode's own configuration file, `~/.config/dmucode/config`, in
/// Ghostty's syntax: one `key = value` per line, `#` comments. Bad lines are
/// skipped and reported, and the rest applies, as libghostty does with the
/// Ghostty config. The only option so far is `keybind`.
public struct AppConfig: Equatable {
    /// The `keybind` lines, in order.
    public var keybinds: [Keybind] = []
    /// What was skipped: "line 3: unknown action: foo".
    public var errors: [String] = []

    public init() {}

    // MARK: Location

    /// `DMUCODE_CONFIG`, else `$XDG_CONFIG_HOME/dmucode/config`
    /// (~/.config/dmucode/config by default).
    public static func path(environment env: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory()) -> String {
        if let override = env["DMUCODE_CONFIG"], !override.isEmpty { return override }
        return directory(environment: env, home: home) + "/config"
    }

    /// The directory watched for changes.
    public static func directory(environment env: [String: String] = ProcessInfo.processInfo.environment,
                                 home: String = NSHomeDirectory()) -> String {
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return (xdg ?? home + "/.config") + "/dmucode"
    }

    /// The config at `path`. No file means the defaults, not an error.
    public static func load(path: String = path()) -> AppConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return AppConfig() }
        return parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> AppConfig {
        var config = AppConfig()
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            func fail(_ message: String) { config.errors.append("line \(index + 1): \(message)") }
            guard let equals = line.firstIndex(of: "=") else {
                fail("expected `key = value`: \(line)")
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "keybind":
                switch Keybind.parse(value) {
                case .success(let keybind): config.keybinds.append(keybind)
                case .failure(let error): fail(error.description)
                }
            default:
                fail("unknown option: \(key)")
            }
        }
        return config
    }

    // MARK: Resolution

    /// The shortcut of each action after the `keybind` lines are applied to
    /// the defaults, in order: binding a trigger takes it from the action
    /// that had it, and `unbind` frees it. Actions without a trigger are
    /// absent.
    public var keybindings: [KeybindAction: KeyTrigger] {
        var bindings = KeybindAction.defaults
        for keybind in keybinds {
            for (action, trigger) in bindings where trigger == keybind.trigger { bindings[action] = nil }
            if let action = keybind.action { bindings[action] = keybind.trigger }
        }
        return bindings
    }
}

/// `keybind = cmd+shift+k=switch_session`, or `...=unbind` to free the trigger.
public struct Keybind: Equatable {
    public let trigger: KeyTrigger
    /// Nil for `unbind`.
    public let action: KeybindAction?

    public init(trigger: KeyTrigger, action: KeybindAction?) {
        self.trigger = trigger
        self.action = action
    }

    /// "trigger=action". The action can't contain "=", so the last "=" splits
    /// (a trigger may be `cmd+=`).
    static func parse(_ text: String) -> Result<Keybind, ConfigError> {
        guard let equals = text.lastIndex(of: "="), equals != text.startIndex else {
            return .failure(ConfigError("expected `trigger=action`: \(text)"))
        }
        let triggerText = text[..<equals].trimmingCharacters(in: .whitespaces)
        let actionText = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        let trigger: KeyTrigger
        switch KeyTrigger.parse(triggerText) {
        case .success(let t): trigger = t
        case .failure(let error): return .failure(error)
        }
        if actionText == "unbind" { return .success(Keybind(trigger: trigger, action: nil)) }
        guard let action = KeybindAction(name: actionText) else {
            return .failure(ConfigError("unknown action: \(actionText)"))
        }
        return .success(Keybind(trigger: trigger, action: action))
    }
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// A key with modifiers, as written in the config: `cmd+shift+k`, `ctrl+up`.
public struct KeyTrigger: Hashable {
    public struct Modifiers: OptionSet, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public enum Key: Hashable {
        /// A printable character, letters in lower case.
        case character(Character)
        case named(NamedKey)
    }

    /// Keys without a character of their own.
    public enum NamedKey: String, CaseIterable {
        case up, down, left, right
        case `return`, tab, escape, space, backspace, delete
        case home, end, pageUp = "page_up", pageDown = "page_down"
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

        var isFunctionKey: Bool { rawValue.hasPrefix("f") }
    }

    public let modifiers: Modifiers
    public let key: Key

    public init(modifiers: Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(_ modifiers: Modifiers = [], _ character: Character) {
        self.init(modifiers: modifiers, key: .character(character))
    }

    public init(_ modifiers: Modifiers = [], _ named: NamedKey) {
        self.init(modifiers: modifiers, key: .named(named))
    }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "super": .command,
        "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option,
        "shift": .shift,
    ]

    /// Names for characters that are awkward to write after a "+".
    private static let characterNames: [String: Character] = [
        "plus": "+", "minus": "-", "equal": "=", "comma": ",", "period": ".", "semicolon": ";",
        "colon": ":", "slash": "/", "backslash": "\\", "grave": "`", "apostrophe": "'", "quote": "\"",
        "bracket_left": "[", "bracket_right": "]",
    ]

    private static let namedAliases: [String: NamedKey] = ["enter": .return, "esc": .escape]

    /// Modifiers and the key, joined with "+". A trailing "+" is the key "+"
    /// (`cmd++`). Letters match regardless of case. A character or arrow key
    /// needs a modifier, or typing it would run the action.
    static func parse(_ text: String) -> Result<KeyTrigger, ConfigError> {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let keyText = parts.popLast(), !keyText.isEmpty else {
            return .failure(ConfigError("expected a key: \(text)"))
        }
        var modifiers = Modifiers()
        for part in parts {
            guard let modifier = modifierNames[part.lowercased()] else {
                return .failure(ConfigError("unknown modifier: \(part)"))
            }
            modifiers.insert(modifier)
        }
        let key: Key
        let lower = keyText.lowercased()
        if keyText.count == 1 {
            key = .character(Character(lower))
        } else if let character = characterNames[lower] {
            key = .character(character)
        } else if let named = NamedKey(rawValue: lower) ?? namedAliases[lower] {
            key = .named(named)
        } else {
            return .failure(ConfigError("unknown key: \(keyText)"))
        }
        let needsModifier: Bool
        switch key {
        case .character: needsModifier = true
        case .named(let named): needsModifier = !named.isFunctionKey
        }
        if needsModifier, modifiers.isEmpty {
            return .failure(ConfigError("\(text) needs a modifier (cmd, ctrl, alt or shift)"))
        }
        return .success(KeyTrigger(modifiers: modifiers, key: key))
    }

    /// As written in the config: "cmd+shift+k".
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        switch key {
        case .character(let c): parts.append(String(c))
        case .named(let n): parts.append(n.rawValue)
        }
        return parts.joined(separator: "+")
    }
}

/// What a shortcut can do: the menu actions. `gotoSession` and `gotoTab`
/// take a position 1–9 (`goto_session:3`).
public enum KeybindAction: Hashable {
    case reloadConfig, hide, quit
    case copy, paste, selectAll
    case tmuxCommand, switchSession
    case newSession, renameSession, killSession, previousSession, nextSession, gotoSession(Int)
    case newTab, renameTab, closeTab, previousTab, nextTab, gotoTab(Int)
    case minimize, toggleFullscreen, toggleSidebar

    private static let names: [(String, KeybindAction)] = [
        ("reload_config", .reloadConfig), ("hide", .hide), ("quit", .quit),
        ("copy", .copy), ("paste", .paste), ("select_all", .selectAll),
        ("tmux_command", .tmuxCommand), ("switch_session", .switchSession),
        ("new_session", .newSession), ("rename_session", .renameSession), ("kill_session", .killSession),
        ("previous_session", .previousSession), ("next_session", .nextSession),
        ("new_tab", .newTab), ("rename_tab", .renameTab), ("close_tab", .closeTab),
        ("previous_tab", .previousTab), ("next_tab", .nextTab),
        ("minimize", .minimize), ("toggle_fullscreen", .toggleFullscreen), ("toggle_sidebar", .toggleSidebar),
    ]

    /// Every action, for a listing: the named ones, then the numbered ones.
    public static let all: [KeybindAction] = names.map(\.1) + (1...9).map(KeybindAction.gotoSession) + (1...9).map(KeybindAction.gotoTab)

    public init?(name: String) {
        if let match = Self.names.first(where: { $0.0 == name }) {
            self = match.1
            return
        }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let n = Int(parts[1]), (1...9).contains(n) else { return nil }
        switch parts[0] {
        case "goto_session": self = .gotoSession(n)
        case "goto_tab": self = .gotoTab(n)
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .gotoSession(let n): return "goto_session:\(n)"
        case .gotoTab(let n): return "goto_tab:\(n)"
        default: return Self.names.first { $0.1 == self }!.0
        }
    }

    /// The shortcuts without a config file.
    public static let defaults: [KeybindAction: KeyTrigger] = {
        var d: [KeybindAction: KeyTrigger] = [
            .reloadConfig: KeyTrigger([.command, .shift], ","),
            .hide: KeyTrigger(.command, "h"),
            .quit: KeyTrigger(.command, "q"),
            .copy: KeyTrigger(.command, "c"),
            .paste: KeyTrigger(.command, "v"),
            .selectAll: KeyTrigger(.command, "a"),
            // ⌘: is ⌘⇧. on US and Finnish layouts, like tmux's prefix :.
            .tmuxCommand: KeyTrigger(.command, ":"),
            // Takes ⌘K from Ghostty's clear_screen; in tmux, `clear` or C-l does that.
            .switchSession: KeyTrigger(.command, "k"),
            .newSession: KeyTrigger(.command, "n"),
            .renameSession: KeyTrigger(.command, "r"),
            // ⌘↑/⌘↓ for sessions (the sidebar is vertical), ⌘←/⌘→ for tabs.
            // These take the keys from Ghostty's own cmd+arrow bindings.
            .previousSession: KeyTrigger(.command, .up),
            .nextSession: KeyTrigger(.command, .down),
            .newTab: KeyTrigger(.command, "t"),
            // ⌥⌘ for the rest of the tab shortcuts keeps them apart from the
            // session ones.
            .renameTab: KeyTrigger([.command, .option], "r"),
            .closeTab: KeyTrigger(.command, "w"),
            .previousTab: KeyTrigger(.command, .left),
            .nextTab: KeyTrigger(.command, .right),
            .minimize: KeyTrigger(.command, "m"),
            // ⌃⌘F, the system's and Ghostty's.
            .toggleFullscreen: KeyTrigger([.command, .control], "f"),
            .toggleSidebar: KeyTrigger([.command, .control], "s"),
        ]
        for n in 1...9 {
            d[.gotoSession(n)] = KeyTrigger(.command, Character("\(n)"))
            d[.gotoTab(n)] = KeyTrigger([.command, .option], Character("\(n)"))
        }
        return d
    }()
}
