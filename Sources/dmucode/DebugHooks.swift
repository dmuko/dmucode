import AppKit
import CoreImage
import IOSurface

/// Test harness for driving the app without Accessibility or Screen
/// Recording permissions. Active only when DMUCODE_DEBUG_DIR is set: the app
/// polls `$DMUCODE_DEBUG_DIR/cmd`, runs each line, then deletes the file.
///
///   snapshot NAME   write the window (sidebar + terminal) to NAME.png
///   type TEXT       synthesize key presses for TEXT ("\n" = Return)
///   ctrl LETTER     synthesize ctrl+LETTER (e.g. tmux prefix: ctrl b)
///   select N        select the Nth session in the sidebar
///   new NAME        create a session (as the New Session button does)
///   state NAME      write the sidebar state (live, selection, sessions) to NAME.txt
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
        case "select":
            if let n = Int(arg), store.sessions.indices.contains(n - 1) {
                store.selectedID = store.sessions[n - 1].id
            }
        case "state":
            var lines = ["live=\(store.isLive) selected=\(store.selectedID ?? "-") title=\(window.title)"]
            lines += store.sessions.map { "\($0.id) \($0.name) windows=\($0.windows) attached=\($0.attachedClients)" }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("\(arg).txt"), atomically: true, encoding: .utf8)
        case "new":
            var newID: String?
            store.perform({ tmux in
                newID = try tmux.newSession(name: arg, directory: NSHomeDirectory())
            }, then: {
                if let newID { store.selectedID = newID }
            })
        default:
            NSLog("debug: unknown command %@", line)
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
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func allTerminals(in view: NSView) -> [TerminalView] {
        if let terminal = view as? TerminalView { return [terminal] }
        return view.subviews.flatMap { allTerminals(in: $0) }
    }
}
