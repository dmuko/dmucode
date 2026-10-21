import Foundation

/// macOS's Full Disk Access. An app can't request it the way it requests
/// the camera or a folder: it can only find out whether it has it and send
/// the user to System Settings. It matters here because programs in tmux
/// run with the access of the app that started the tmux server, so without
/// it they can't read Documents, Desktop or Downloads, and once that app
/// has quit, some of them fail with "Operation not permitted" without any
/// prompt at all.
public enum FullDiskAccess {
    /// Whether this process has Full Disk Access, found out by opening a
    /// file that only Full Disk Access allows. The attempt also lists the
    /// app in System Settings' Full Disk Access pane, switched off, so the
    /// user can turn it on there without adding the app by hand.
    public static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        let fd = open(home + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// The Full Disk Access pane in System Settings.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Whether to ask at launch: only while the access is missing, unless
    /// the user chose Don't Ask Again or the config says
    /// `full-disk-access-prompt = false`.
    public static func shouldPrompt(config: AppConfig, dismissed: Bool, granted: Bool) -> Bool {
        config.fullDiskAccessPrompt && !dismissed && !granted
    }
}
