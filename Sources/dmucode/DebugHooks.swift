import AppKit
import CoreImage
import dmucodeCore
import IOSurface

/// Test harness for driving the app without Accessibility or Screen
/// Recording permissions. Active only when DMUCODE_DEBUG_DIR is set: the app
/// polls `$DMUCODE_DEBUG_DIR/cmd`, runs each line, then deletes the file.
///
///   snapshot NAME   write the window (sidebar + terminal) to NAME.png
///   type TEXT       synthesize key presses for TEXT ("\n" = Return)
///   ctrl LETTER     synthesize ctrl+LETTER (e.g. tmux prefix: ctrl b)
///   key MODS+KEY    run the menu item with that shortcut (e.g. key cmd+right)
///   press KEY       synthesize up, down, escape, tab or backspace
///   click X Y       click at X,Y points from the window's top-left corner
///   select N        select the Nth session in the sidebar
///   tab N           select the Nth window tab of the selected session
///   newtab          open a new window in the selected session (the + button)
///   reload          reload the Ghostty config (state shows the theme and errors)
///   fda             open the Full Disk Access sheet, as the menu item does
///   hide            hide the app (⌘H); unhide brings it back
///   move FROM TO    drag sidebar row FROM (0-based) to before row TO, as onMove does
///   group NAME      create a group; ungroup NAME removes it
///   togroup S G     move session S into group G ("-": out of its group)
///   collapse NAME   hide group NAME's sessions, or show them again (as a click on its header)
///   cmdbar LINE     run tmux command LINE in the palette (state shows the result)
///   palette TEXT    type TEXT into the palette and press Return
///   new NAME        create a session (as the New Session button does)
///   state NAME      write the sidebar state (live, selection, sessions, keybinds) to NAME.txt
///   pixels NAME     write raw RGBA samples of the visible terminal's IOSurface to NAME.txt
enum DebugHooks {
    private static var timer: Timer?

    static func install(window: NSWindow, store: SessionStore) {
        guard let dir = ProcessInfo.processInfo.environment["DMUCODE_DEBUG_DIR"] else { return }
        let cmdURL = URL(fileURLWithPath: dir).appendingPathComponent("cmd")
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard let text = try? String(contentsOf: cmdURL, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: cmdURL)
            for line in text.split(separator: "\n") {
                run(String(line), dir: dir, window: window, store: store)
            }
        }
    }

    private static func run(_ line: String, dir: String, window: NSWindow, store: SessionStore) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch command {
        case "snapshot":
            snapshot(window: window, to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).png"))
        case "type":
            for ch in arg.replacingOccurrences(of: "\\n", with: "\n") { key(String(ch), window: window) }
        case "ctrl":
            key(arg, flags: .control, window: window)
        case "key":
            shortcut(arg, window: window)
        case "press":
            press(arg, window: window)
        case "click":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 2 { click(x: n[0], y: n[1], window: window) }
        case "select":
            if let n = Int(arg), store.sessions.indices.contains(n - 1) {
                store.selectedID = store.sessions[n - 1].id
            }
        case "state":
            var lines = ["live=\(store.isLive) selected=\(store.selectedID ?? "-") title=\(window.title) opaque=\(window.isOpaque) restoring=\(store.isRestoring) error=\(store.errorMessage ?? "-") key=\(window.isKeyWindow) active=\(NSApp.isActive) windowNumber=\(window.windowNumber) size=\(Int(window.frame.width))x\(Int(window.frame.height))"]
            if let controller = window.windowController as? MainWindowController {
                lines.append(controller.paletteState)
                lines.append(controller.themeState)
                lines.append(controller.fullDiskAccessState)
                lines.append(controller.notificationState)
            }
            if let delegate = NSApp.delegate as? AppDelegate {
                lines.append("keybinds=" + delegate.menuDebugState)
                lines.append("settings=" + delegate.settingsDebugState)
            }
            lines.append("firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
            if let editor = window.firstResponder as? NSTextView {
                lines.append("fieldEditor=[\(editor.string)] cursor=\(editor.selectedRange().location)")
            }
            let rows = store.sidebarRows.map { row -> String in
                switch row {
                case .group(let name): return "#" + name + (store.layout.isCollapsed(name) ? "(collapsed)" : "")
                case .session(let session):
                    let shown = store.layout.displayName(ofSession: session.name)
                    return session.name + (shown == session.name ? "" : "=" + shown)
                }
            }
            lines.append("rows=[\(rows.joined(separator: ","))]")
            lines += store.sessions.map { session in
                let windows = session.windows.map {
                    "\($0.id)\($0.isActive ? "*" : "")\($0.hasBell ? "!" : "")\($0.hasActivity ? "#" : ""):\($0.name)"
                }
                let alert = store.alerts[session.id].map { " alert=\($0.message ?? "bell")" } ?? ""
                let working = store.isWorking(session) ? " working" : ""
                return "\(session.id) \(session.name) windows=[\(windows.joined(separator: ","))] attached=\(session.attachedClients)\(alert)\(working)"
            }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).txt"), atomically: true, encoding: .utf8)
        case "pixels":
            var lines: [String] = []
            for terminal in allTerminals(in: window.contentView!) where !terminal.isHidden {
                guard let contents = terminal.layer?.contents,
                      CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { continue }
                let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                IOSurfaceLock(surface, .readOnly, nil)
                let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
                let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
                let stride = IOSurfaceGetBytesPerRow(surface)
                lines.append("size=\(width)x\(height) format=\(IOSurfaceGetPixelFormat(surface))")
                for (x, y) in [(width / 2, height / 2), (width - 20, height - 20), (40, 40)] {
                    let p = base + y * stride + x * 4
                    lines.append("(\(x),\(y)) bytes=\(p[0]) \(p[1]) \(p[2]) \(p[3])")
                }
                IOSurfaceUnlock(surface, .readOnly, nil)
            }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).txt"), atomically: true, encoding: .utf8)
        case "tab":
            if let n = Int(arg), let session = store.selectedSession, session.windows.indices.contains(n - 1) {
                store.selectWindow(session.windows[n - 1].id, in: session.id)
            }
        case "reload":
            GhosttyRuntime.shared.reloadConfig()
        case "hide":
            NSApp.hide(nil)
        case "unhide":
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        case "fda":
            (window.windowController as? MainWindowController)?.showFullDiskAccess(nil)
        case "move":
            let n = arg.split(separator: " ").compactMap { Int($0) }
            if n.count == 2 { store.moveSidebarRow(from: n[0], to: n[1]) }
        case "group":
            store.addGroup(arg)
        case "ungroup":
            store.removeGroup(arg)
        case "collapse":
            store.toggleGroupCollapsed(arg)
        case "togroup":
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let session = store.sessions.first(where: { $0.name == parts[0] }) {
                store.setGroup(parts[1] == "-" ? nil : parts[1], forSession: session.id)
            }
        case "cmdbar":
            (window.windowController as? MainWindowController)?.runInPalette(":" + arg)
        case "palette":
            (window.windowController as? MainWindowController)?.runInPalette(arg)
        case "newtab":
            if let id = store.selectedID {
                store.perform { tmux in try tmux.newWindow(sessionID: id) }
            }
        case "new":
            var newID: String?
            store.perform({ tmux in
                newID = try tmux.newSession(name: arg, directory: NSHomeDirectory())
            }, then: {
                if let newID { store.selectedID = newID }
            })
        default:
            Log.debug.error("unknown command \(line, privacy: .public)")
        }
    }

    // US ANSI virtual keycodes for the characters the tests use.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        " ": 49, "\n": 36, "-": 27, ".": 47, "/": 44, "'": 39, "\"": 39,
    ]

    private static func key(_ text: String, flags: NSEvent.ModifierFlags = [], window: NSWindow) {
        guard let ch = text.lowercased().first else { return }
        let code = keyCodes[ch] ?? 0
        var chars = ch == "\n" ? "\r" : text
        if flags.contains(.control), let ascii = ch.asciiValue, ch.isLetter {
            chars = String(UnicodeScalar(ascii & 0x1F))
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: ch == "\n" ? "\r" : String(ch),
                isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    /// A key without text, sent to the first responder like a real press.
    /// A click at (x, y) in points from the window's top-left corner, through
    /// the window's own hit testing (so the title bar area counts).
    private static func click(x: Double, y: Double, window: NSWindow) {
        let point = NSPoint(x: x, y: window.frame.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }

    private static func press(_ name: String, window: NSWindow) {
        let keys: [String: (code: UInt16, char: String, flags: NSEvent.ModifierFlags)] = [
            "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.numericPad, .function]),
            "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.numericPad, .function]),
            "escape": (53, "\u{1b}", []),
            "tab": (48, "\t", []),
            "backspace": (51, "\u{7f}", []),
        ]
        guard let key = keys[name] else {
            Log.debug.error("unknown key \(name, privacy: .public)")
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: key.char, charactersIgnoringModifiers: key.char,
                isARepeat: false, keyCode: key.code) else { continue }
            (window.attachedSheet ?? window).sendEvent(event)
        }
    }

    private static func shortcut(_ spec: String, window: NSWindow) {
        var parts = spec.split(separator: "+").map(String.init)
        guard let name = parts.popLast() else { return }
        var flags: NSEvent.ModifierFlags = []
        for mod in parts {
            switch mod {
            case "cmd": flags.insert(.command)
            case "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            default: return
            }
        }
        let arrows = ["left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
                      "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey]
        let key = arrows[name].map { String(UnicodeScalar($0)!) } ?? name
        // Matched by hand: AppKit finds a menu action's target through the
        // key window, and an inactive app (usually a test instance) has none.
        guard let item = menuItems(NSApp.mainMenu).first(where: {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask == flags
        }), let action = item.action else {
            Log.debug.error("no menu item for \(spec, privacy: .public)")
            return
        }
        // Like AppKit: the first responder in the chain that implements the
        // action is the target, and it decides whether the item is enabled.
        var target = window.firstResponder
        while let responder = target, !responder.responds(to: action) { target = responder.nextResponder }
        guard let target else {
            Log.debug.error("nothing handles \(spec, privacy: .public)")
            return
        }
        if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
            Log.debug.error("\(spec, privacy: .public) is disabled (target \(String(describing: type(of: target)), privacy: .public))")
            return
        }
        target.perform(action, with: item)
    }

    private static func menuItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + menuItems($0.submenu) }
    }

    /// AppKit views are rendered with cacheDisplay; terminal surfaces draw
    /// with Metal into an IOSurface layer, so those are composited on top.
    private static func snapshot(window: NSWindow, to url: URL) {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.lockFocus()
        rep.draw(in: content.bounds)
        let ci = CIContext()
        for terminal in allTerminals(in: content) where !terminal.isHidden {
            guard let contents = terminal.layer?.contents,
                  CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { continue }
            let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            let ciImage = CIImage(ioSurface: surface)
            guard let cg = ci.createCGImage(ciImage, from: ciImage.extent) else { continue }
            let frame = terminal.convert(terminal.bounds, to: content)
            // Ghostty anchors its contents top-left at backing resolution.
            let scale = window.backingScaleFactor
            let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
            let rect = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
            NSImage(cgImage: cg, size: size).draw(in: rect)
        }
        // Views stacked above the terminals (e.g. the command bar) were
        // painted over by the terminal images; draw them again on top.
        for overlay in overlays(in: content) {
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            // sourceOver: draw(in:) would copy the transparent margins as-is.
            rep.draw(in: overlay.convert(overlay.bounds, to: content), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Visible siblings above a terminal in z-order.
    private static func overlays(in content: NSView) -> [NSView] {
        guard let terminal = allTerminals(in: content).first, let parent = terminal.superview else { return [] }
        let firstTerminal = parent.subviews.firstIndex { $0 is TerminalView } ?? 0
        return parent.subviews[(firstTerminal + 1)...].filter { !($0 is TerminalView) && !$0.isHidden }
    }

    private static func allTerminals(in view: NSView) -> [TerminalView] {
        if let terminal = view as? TerminalView { return [terminal] }
        return view.subviews.flatMap { allTerminals(in: $0) }
    }
}
