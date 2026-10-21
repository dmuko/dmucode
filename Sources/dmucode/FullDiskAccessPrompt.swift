import AppKit
import dmucodeCore

/// The sheet that asks for Full Disk Access: at launch while it's missing,
/// until the user chooses Don't Ask Again or `full-disk-access-prompt =
/// false`, and from dmucode → Full Disk Access… at any time. macOS has no
/// way to request the access, so the sheet explains and opens System
/// Settings; the user turns dmucode on there.
enum FullDiskAccessPrompt {
    static let dismissedKey = "fullDiskAccessPromptDismissed"

    /// Don't Ask Again.
    static var isDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    /// Why dmucode wants it; `tmux` is the binary's path, for the hint
    /// about servers dmucode didn't start.
    static func explanation(tmux: String, granted: Bool) -> String {
        let covered = "Programs in tmux run with the access of the app that started the tmux server, "
            + (granted
                ? "so programs in servers started by dmucode can read every folder."
                : "so with Full Disk Access for dmucode they can read every folder.")
        let others = "For a server started from another terminal, add tmux itself (\(tmux)) to the list as well."
        if granted { return covered + " " + others }
        return "macOS keeps programs out of Documents, Desktop, Downloads and other protected folders unless the app "
            + "they run under is allowed in. " + covered + "\n\nIn System Settings, turn on dmucode under "
            + "Privacy & Security › Full Disk Access. " + others
    }

    /// Shows the sheet. From the menu it's shown even when the access is
    /// there, saying so; at launch only while it's missing.
    static func show(on window: NSWindow, tmux: String, granted: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = granted ? "dmucode has Full Disk Access" : "Give dmucode Full Disk Access"
        alert.informativeText = explanation(tmux: tmux, granted: granted)
        if granted {
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open System Settings")
        } else {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Don't Ask Again")
        }
        alert.beginSheetModal(for: window) { response in
            switch (granted, response) {
            case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn):
                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
            case (false, .alertThirdButtonReturn):
                isDismissed = true
            default:
                break
            }
        }
    }
}
