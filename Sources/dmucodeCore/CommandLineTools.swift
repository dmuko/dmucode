import Foundation

/// dmucode → Install Command Line Tools…: symlinks to the `dmucode` and
/// `notify` scripts in the app bundle, in a directory on the user's PATH.
public enum CommandLineTools {
    public static let names = ["dmucode", "notify"]

    /// Where the links go by preference: the user's own directories first,
    /// then the system-wide ones (Homebrew's is where its casks link).
    public static func preferredDirectories(home: String) -> [String] {
        [home + "/bin", home + "/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"]
    }

    public enum DirectoryState {
        case missing, writable, readOnly, notADirectory
    }

    /// The directory to propose: the first preferred one that is on `path`
    /// and writable, or missing under the home directory (it's created).
    public static func proposedDirectory(path: [String], home: String, state: (String) -> DirectoryState) -> String? {
        let onPath = Set(path)
        return preferredDirectories(home: home).first { directory in
            guard onPath.contains(directory) else { return false }
            switch state(directory) {
            case .writable: return true
            case .missing: return directory.hasPrefix(home + "/")
            case .readOnly, .notADirectory: return false
            }
        }
    }

    public static func state(of directory: String, fileManager: FileManager = .default) -> DirectoryState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notADirectory }
        return fileManager.isWritableFile(atPath: directory) ? .writable : .readOnly
    }

    public enum Outcome: Equatable {
        /// A new link.
        case linked
        /// The link was already there, pointing at this app.
        case alreadyLinked
        /// A link to the script in another copy of dmucode was repointed.
        case replaced(previous: String)
        /// Something else has the name; left alone.
        case inTheWay
    }

    /// Links each of `sources` (the scripts, by path) into `directory` under
    /// its own name, creating the directory if needed. Throws for the
    /// directory or a link that couldn't be made; what was in the way is an
    /// outcome, not an error.
    public static func install(_ sources: [String], into directory: String,
                               fileManager: FileManager = .default) throws -> [(name: String, outcome: Outcome)] {
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return try sources.map { source in
            let name = (source as NSString).lastPathComponent
            let link = (directory as NSString).appendingPathComponent(name)
            if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link) {
                if existing == source { return (name, .alreadyLinked) }
                guard existing.contains("/Contents/Resources/bin/") else { return (name, .inTheWay) }
                try fileManager.removeItem(atPath: link)
                try fileManager.createSymbolicLink(atPath: link, withDestinationPath: source)
                return (name, .replaced(previous: existing))
            }
            if fileManager.fileExists(atPath: link) { return (name, .inTheWay) }
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: source)
            return (name, .linked)
        }
    }
}
