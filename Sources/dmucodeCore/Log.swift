import os

/// The app's loggers, all under one subsystem, so
/// `log show --predicate 'subsystem == "com.dmuko.dmucode"'` has everything.
public enum Log {
    public static let subsystem = "com.dmuko.dmucode"

    /// The tmux control-mode connection.
    public static let control = Logger(subsystem: subsystem, category: "control")
    /// libghostty and its configuration.
    public static let ghostty = Logger(subsystem: subsystem, category: "ghostty")
    /// dmucode's own config file.
    public static let config = Logger(subsystem: subsystem, category: "config")
    /// dmucode: URLs (the dmucode command).
    public static let url = Logger(subsystem: subsystem, category: "url")
    /// The debug hook (DMUCODE_DEBUG_DIR).
    public static let debug = Logger(subsystem: subsystem, category: "debug")
}
