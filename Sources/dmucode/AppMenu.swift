import AppKit
import dmucodeCore

/// The main menu, with the shortcuts from the config. Each item that a
/// `keybind` can change is kept by its action, so a reload only updates key
/// equivalents and the menu is never rebuilt.
final class AppMenu {
    let menu = NSMenu()
    private var items: [KeybindAction: NSMenuItem] = [:]

    init() {
        let app = NSMenu()
        // Reloads the dmucode and the Ghostty config; saving either reloads it too.
        add(app, "Reload Config", .reloadConfig, #selector(MainWindowController.reloadConfig(_:)))
        // No keybind: explains and opens System Settings; see FullDiskAccessPrompt.
        app.addItem(withTitle: "Full Disk Access…", action: #selector(MainWindowController.showFullDiskAccess(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, "Hide dmucode", .hide, #selector(NSApplication.hide(_:)))
        app.addItem(.separator())
        // Quitting only detaches: the tmux sessions keep running.
        add(app, "Quit dmucode", .quit, #selector(NSApplication.terminate(_:)))
        menu.addItem(submenu: app, title: "dmucode")

        let edit = NSMenu(title: "Edit")
        add(edit, "Copy", .copy, #selector(TerminalView.copy(_:)))
        add(edit, "Paste", .paste, #selector(TerminalView.paste(_:)))
        add(edit, "Select All", .selectAll, #selector(NSResponder.selectAll(_:)))
        menu.addItem(submenu: edit, title: "Edit")

        let session = NSMenu(title: "Session")
        add(session, "tmux Command…", .tmuxCommand, #selector(MainWindowController.toggleCommandBar(_:)))
        add(session, "Switch to Session…", .switchSession, #selector(MainWindowController.toggleSwitcher(_:)))
        session.addItem(.separator())
        add(session, "New Session…", .newSession, #selector(MainWindowController.newSession(_:)))
        add(session, "Rename Session…", .renameSession, #selector(MainWindowController.renameSelected(_:)))
        add(session, "Kill Session…", .killSession, #selector(MainWindowController.killSelected(_:)))
        session.addItem(.separator())
        add(session, "Previous Session", .previousSession, #selector(MainWindowController.selectPreviousSession(_:)))
        add(session, "Next Session", .nextSession, #selector(MainWindowController.selectNextSession(_:)))
        session.addItem(.separator())
        for i in 1...9 {
            add(session, "Session \(i)", .gotoSession(i), #selector(MainWindowController.selectSessionByTag(_:))).tag = i
        }
        menu.addItem(submenu: session, title: "Session")

        // Tabs are the selected session's tmux windows.
        let tab = NSMenu(title: "Tab")
        add(tab, "New Tab", .newTab, #selector(MainWindowController.newTab(_:)))
        add(tab, "Rename Tab…", .renameTab, #selector(MainWindowController.renameTab(_:)))
        add(tab, "Close Tab…", .closeTab, #selector(MainWindowController.closeTab(_:)))
        tab.addItem(.separator())
        add(tab, "Previous Tab", .previousTab, #selector(MainWindowController.selectPreviousTmuxWindow(_:)))
        add(tab, "Next Tab", .nextTab, #selector(MainWindowController.selectNextTmuxWindow(_:)))
        tab.addItem(.separator())
        for i in 1...9 {
            add(tab, "Tab \(i)", .gotoTab(i), #selector(MainWindowController.selectTabByTag(_:))).tag = i
        }
        menu.addItem(submenu: tab, title: "Tab")

        let window = NSMenu(title: "Window")
        add(window, "Minimize", .minimize, #selector(NSWindow.performMiniaturize(_:)))
        // AppKit retitles it to Exit Full Screen.
        add(window, "Enter Full Screen", .toggleFullscreen, #selector(NSWindow.toggleFullScreen(_:)))
        add(window, "Toggle Sidebar", .toggleSidebar, #selector(NSSplitViewController.toggleSidebar(_:)))
        menu.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        apply(KeybindAction.defaults)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: KeybindAction, _ selector: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        items[action] = item
        return item
    }

    /// Sets every item's shortcut; actions missing from `bindings` get none.
    func apply(_ bindings: [KeybindAction: KeyTrigger]) {
        for (action, item) in items {
            if let trigger = bindings[action] {
                item.keyEquivalent = Self.keyEquivalent(trigger.key)
                item.keyEquivalentModifierMask = Self.modifierMask(trigger.modifiers)
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    /// "action=trigger" for each item with a shortcut, for the debug hook.
    var debugState: String {
        items.compactMap { action, item -> String? in
            guard !item.keyEquivalent.isEmpty else { return nil }
            return action.name + "=" + Self.describe(item.keyEquivalent, item.keyEquivalentModifierMask)
        }.sorted().joined(separator: ",")
    }

    static func modifierMask(_ modifiers: KeyTrigger.Modifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }

    private static let namedKeys: [KeyTrigger.NamedKey: String] = {
        func s(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        return [
            .up: s(NSUpArrowFunctionKey), .down: s(NSDownArrowFunctionKey),
            .left: s(NSLeftArrowFunctionKey), .right: s(NSRightArrowFunctionKey),
            .return: "\r", .tab: "\t", .escape: "\u{1B}", .space: " ",
            .backspace: "\u{8}", .delete: s(NSDeleteFunctionKey),
            .home: s(NSHomeFunctionKey), .end: s(NSEndFunctionKey),
            .pageUp: s(NSPageUpFunctionKey), .pageDown: s(NSPageDownFunctionKey),
            .f1: s(NSF1FunctionKey), .f2: s(NSF2FunctionKey), .f3: s(NSF3FunctionKey), .f4: s(NSF4FunctionKey),
            .f5: s(NSF5FunctionKey), .f6: s(NSF6FunctionKey), .f7: s(NSF7FunctionKey), .f8: s(NSF8FunctionKey),
            .f9: s(NSF9FunctionKey), .f10: s(NSF10FunctionKey), .f11: s(NSF11FunctionKey), .f12: s(NSF12FunctionKey),
        ]
    }()

    static func keyEquivalent(_ key: KeyTrigger.Key) -> String {
        switch key {
        case .character(let c): return String(c)
        case .named(let n): return namedKeys[n]!
        }
    }

    private static func describe(_ keyEquivalent: String, _ mask: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if mask.contains(.control) { parts.append("ctrl") }
        if mask.contains(.option) { parts.append("alt") }
        if mask.contains(.shift) { parts.append("shift") }
        if mask.contains(.command) { parts.append("cmd") }
        parts.append(namedKeys.first { $0.value == keyEquivalent }?.key.rawValue ?? keyEquivalent)
        return parts.joined(separator: "+")
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
