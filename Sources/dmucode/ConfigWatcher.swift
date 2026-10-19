import CoreServices
import Foundation

/// Calls back on the main thread when a Ghostty config file is saved, so
/// changes apply without the reload shortcut. FSEvents on the config
/// directories also sees editors that save by writing a new file and
/// renaming it over the old one. Reacts to `config`, `config.ghostty` and
/// files under `themes/`; files included with `config-file` from elsewhere
/// aren't watched.
final class ConfigWatcher {
    private var stream: FSEventStreamRef?
    private let directories: [String]
    private let onChange: () -> Void

    /// Where libghostty looks for `config` and `config.ghostty`:
    /// $XDG_CONFIG_HOME/ghostty (~/.config/ghostty by default) and
    /// ~/Library/Application Support/com.mitchellh.ghostty.
    static var defaultDirectories: [String] {
        let home = NSHomeDirectory()
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return [(xdg ?? home + "/.config") + "/ghostty", home + "/Library/Application Support/com.mitchellh.ghostty"]
    }

    /// Nil if none of the directories exists.
    init?(directories: [String], onChange: @escaping () -> Void) {
        // FSEvents reports canonical paths (/private/tmp, not /tmp).
        let existing = directories.compactMap { path -> String? in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard !existing.isEmpty else { return nil }
        self.directories = existing
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.changed(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        // 0.3 s latency coalesces an editor's several writes into one batch.
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func changed(_ paths: [String]) {
        let relevant = paths.contains { path in
            directories.contains { directory in
                guard path.hasPrefix(directory + "/") else { return false }
                let file = path.dropFirst(directory.count + 1)
                return file == "config" || file == "config.ghostty" || file.hasPrefix("themes/")
            }
        }
        if relevant { onChange() }
    }
}
