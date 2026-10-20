import AppKit
import dmucodeCore
import GhosttyKit

/// Owns the process-wide `ghostty_app_t` and answers libghostty's runtime
/// callbacks. Callbacks that concern one surface arrive with that surface's
/// userdata, which is its `TerminalView`.
final class GhosttyRuntime: ObservableObject {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    /// The config in effect, for the chrome's colors. After a reload it is
    /// the one libghostty applied (CONFIG_CHANGE), with conditional parts
    /// such as `theme = light:…,dark:…` resolved.
    private var config: ghostty_config_t?
    private var watcher: ConfigWatcher?

    /// The terminal colors the window chrome should match.
    @Published private(set) var theme = TerminalTheme(background: .black, foreground: .white, opacity: 1)
    /// Problems in the last loaded config (unknown keys, bad values...).
    /// libghostty skips those lines and applies the rest, as Ghostty does.
    @Published private(set) var configErrors: [String] = []

    private init() {}

    /// Loads the user's Ghostty config (~/.config/ghostty/config) so fonts and
    /// themes match their Ghostty, and creates the app.
    func start() -> Bool {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            return false
        }
        guard let config = loadConfig() else { return false }
        setConfig(config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                // May be called from any thread.
                DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
            },
            action_cb: { _, target, action in
                GhosttyRuntime.shared.handleAction(target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, _ in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { _, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, _ in
                guard let view = TerminalView.from(userdata) else { return }
                DispatchQueue.main.async { view.onClose?() }
            }
        )
        guard let app = ghostty_app_new(&runtime, config) else { return false }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        watcher = ConfigWatcher(directories: ConfigWatcher.defaultDirectories) { [weak self] in
            self?.reloadConfig()
        }
        return true
    }

    // MARK: Config

    /// Reads the config files again and applies them to every terminal
    /// (⌘⇧, or Ghostty's reload_config binding, or a saved config file).
    func reloadConfig() {
        guard let app, let new = loadConfig() else { return }
        // Updates every surface, then reports the applied config through
        // CONFIG_CHANGE, which takes it over (see setConfig). The caller
        // keeps ownership of `new`.
        ghostty_app_update_config(app, new)
        ghostty_config_free(new)
    }

    /// A fresh config from the default files, its problems published.
    private func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        var errors: [String] = []
        for i in 0..<ghostty_config_diagnostics_count(config) {
            if let message = ghostty_config_get_diagnostic(config, i).message {
                errors.append(String(cString: message))
            }
        }
        for error in errors { Log.ghostty.error("config: \(error, privacy: .public)") }
        configErrors = errors
        return config
    }

    /// Takes ownership of `config` for the chrome's colors.
    private func setConfig(_ config: ghostty_config_t) {
        if let old = self.config { ghostty_config_free(old) }
        self.config = config
        let theme = TerminalTheme(
            background: color("background") ?? .black,
            foreground: color("foreground") ?? .white,
            opacity: backgroundOpacity)
        if theme != self.theme { self.theme = theme }
    }

    /// `background-opacity` from the Ghostty config; 1 means opaque.
    private var backgroundOpacity: Double {
        guard let config else { return 1 }
        var value: Double = 1
        let key = "background-opacity"
        _ = ghostty_config_get(config, &value, key, UInt(key.utf8.count))
        return value
    }

    private func color(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var value = ghostty_config_color_s()
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(
            srgbRed: CGFloat(value.r) / 255,
            green: CGFloat(value.g) / 255,
            blue: CGFloat(value.b) / 255,
            alpha: 1)
    }

    /// `bell-features`: which of Ghostty's bell effects are on. dmucode
    /// plays `system` (the alert sound) and `audio` (bell-audio-path); the
    /// attention marker in the sidebar is shown regardless.
    struct BellFeatures: OptionSet {
        let rawValue: CUnsignedInt
        static let system = BellFeatures(rawValue: 1 << 0)
        static let audio = BellFeatures(rawValue: 1 << 1)
        static let attention = BellFeatures(rawValue: 1 << 2)
        static let title = BellFeatures(rawValue: 1 << 3)
        static let border = BellFeatures(rawValue: 1 << 4)
        /// Ghostty's default: no sound.
        static let defaultValue = BellFeatures([.attention, .title])
    }

    var bellFeatures: BellFeatures {
        guard let config else { return .defaultValue }
        var value: CUnsignedInt = 0
        let key = "bell-features"
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return .defaultValue }
        return BellFeatures(rawValue: value)
    }

    private func playBell() {
        let features = bellFeatures
        if features.contains(.system) { NSSound.beep() }
        guard features.contains(.audio), let config else { return }
        var path = ghostty_config_path_s()
        let pathKey = "bell-audio-path"
        guard ghostty_config_get(config, &path, pathKey, UInt(pathKey.utf8.count)), let cPath = path.path else { return }
        var volume: Double = 0.5
        let volumeKey = "bell-audio-volume"
        _ = ghostty_config_get(config, &volume, volumeKey, UInt(volumeKey.utf8.count))
        guard let sound = NSSound(contentsOfFile: String(cString: cPath), byReference: false) else { return }
        sound.volume = Float(volume)
        sound.play()
    }

    /// Applies `background-blur` behind a see-through window. libghostty
    /// does nothing when background-opacity is 1 or blur is off.
    func setBackgroundBlur(_ window: NSWindow) {
        guard let app else { return }
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // libghostty forces wait-after-command for surfaces given a
            // command, so the tmux client exiting (detach, session killed)
            // would leave a "Press any key" screen. Close the view instead.
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let view = TerminalView.from(ghostty_surface_userdata(surface)) else { return false }
            DispatchQueue.main.async { view.onClose?() }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            // tmux forwards a bell from any window of the session to its
            // clients, so this also covers windows not on screen. The
            // attention marker is dmucode's own; the sound follows Ghostty's
            // bell-features, as in Ghostty's app.
            let view = Self.view(target)
            DispatchQueue.main.async {
                self.playBell()
                view?.onAlert?(nil)
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // OSC 9 / OSC 777 (through tmux passthrough), e.g. Claude Code
            // waiting for input. The strings live only during the callback.
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            let view = Self.view(target)
            DispatchQueue.main.async { view?.onAlert?(body.isEmpty ? title : body) }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Ghostty's reload_config binding (⌘⇧, by default). A soft reload
            // re-applies the config in effect. Always app-wide: one config.
            let soft = action.action.reload_config.soft
            DispatchQueue.main.async {
                guard let app = self.app else { return }
                if soft, let config = self.config {
                    ghostty_app_update_config(app, config)
                } else if !soft {
                    self.reloadConfig()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // The applied config lives only during the callback: clone it.
            guard target.tag == GHOSTTY_TARGET_APP,
                  let applied = action.action.config_change.config,
                  let clone = ghostty_config_clone(applied) else { return false }
            DispatchQueue.main.async { self.setConfig(clone) }
            return true
        default:
            // Everything else (Ghostty tabs, splits, windows, title...) is
            // either tmux's job here or not handled yet.
            return false
        }
    }

    private static func view(_ target: ghostty_target_s) -> TerminalView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return TerminalView.from(ghostty_surface_userdata(surface))
    }

    // MARK: Clipboard

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = TerminalView.from(userdata)?.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let text = NSPasteboard.general.string(forType: .string) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        complete(surface, text: text, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty asks for confirmation before unsafe pastes (e.g. multi-line
    /// text into a shell) and before programs read the clipboard via OSC 52.
    /// The request stays pending until we complete or deny it, so the
    /// contents are copied and the prompt is shown after the callback returns.
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalView.from(userdata), let surface = view.surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE,
              let confirm = confirm?.pointee,
              let text = plainText(confirm.contents, count: confirm.contents_len) else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Paste potentially unsafe text?"
            alert.informativeText = String(text.prefix(500))
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                complete(surface, text: text, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    private static func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        // Writes that need confirmation come from programs (OSC 52); they
        // aren't handled yet and are ignored.
        guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm,
              let text = plainText(content, count: len) else { return }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private static func plainText(
        _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) -> String? {
        guard let contents else { return nil }
        for i in 0..<count {
            let item = contents[i]
            guard let mime = item.mime, String(cString: mime) == "text/plain",
                  let data = item.data else { continue }
            let bytes = UnsafeRawBufferPointer(start: data, count: item.len)
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        text: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        // utf8CString is NUL-terminated, so it has storage even for "".
        let bytes = text.utf8CString
        "text/plain".withCString { mime in
            bytes.withUnsafeBufferPointer { buf in
                var content = ghostty_clipboard_content_s(
                    mime: mime, data: buf.baseAddress, len: buf.count - 1)
                withUnsafePointer(to: &content) { contentPtr in
                    var done = ghostty_clipboard_complete_s(
                        contents: contentPtr,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: confirmed,
                        remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &done, state)
                }
            }
        }
    }
}

struct TerminalTheme: Equatable {
    let background: NSColor
    let foreground: NSColor
    /// `background-opacity`; below 1 the window is see-through.
    let opacity: Double

    var isTranslucent: Bool { opacity < 1 }

    /// Chrome (title bar, sidebar) background, as translucent as the terminals.
    var chromeBackground: NSColor { background.withAlphaComponent(opacity) }

    /// The same colors without translucency.
    var opaque: TerminalTheme { TerminalTheme(background: background, foreground: foreground, opacity: 1) }

    /// Dark or light system appearance, so text and controls stay readable.
    var appearance: NSAppearance? {
        let c = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
    }
}
