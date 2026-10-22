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
    /// path that only Full Disk Access allows. The attempt also lists the
    /// app in System Settings' Full Disk Access pane, switched off, so the
    /// user can turn it on there without adding the app by hand.
    public static func isGranted(home: String = NSHomeDirectory()) -> Bool {
        isGranted(probing: probePaths(home: home))
    }

    /// Paths only Full Disk Access opens. Not every Mac has every one (the
    /// per-user TCC database is missing on macOS 27), so several are tried.
    static func probePaths(home: String) -> [String] {
        [home + "/Library/Application Support/com.apple.TCC/TCC.db",
         "/Library/Application Support/com.apple.TCC/TCC.db",
         home + "/Library/Safari"]
    }

    /// The first path that exists decides: opened means granted, refused
    /// means not. A missing path says nothing, so the next one is tried;
    /// when none exists, the access counts as missing.
    static func isGranted(probing paths: [String]) -> Bool {
        for path in paths {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno != ENOENT { return false }
        }
        return false
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
