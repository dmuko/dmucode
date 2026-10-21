import AppKit
import dmucodeCore

/// dmucode → Install Command Line Tools…: proposes a directory on the login
/// shell's PATH (see `CommandLineTools.proposedDirectory`), lets the user
/// pick another, makes the links and reports.
enum CommandLineToolsPrompt {
    /// The scripts in this app bundle.
    static var sources: [String] {
        let bin = Bundle.main.resourceURL!.appendingPathComponent("bin")
        return CommandLineTools.names.map { bin.appendingPathComponent($0).path }
    }

    static func show(on window: NSWindow) {
        // The login shell may take a moment (profiles, banners).
        DispatchQueue.global().async {
            let path = ExecutableLookup().loginShellPath() ?? []
            DispatchQueue.main.async { propose(on: window, path: path) }
        }
    }

    private static func propose(on window: NSWindow, path: [String]) {
        guard window.attachedSheet == nil else { return }
        let home = NSHomeDirectory()
        let proposed = CommandLineTools.proposedDirectory(path: path, home: home, state: { CommandLineTools.state(of: $0) })
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install the dmucode and notify commands"
        let what = "dmucode shows or creates sessions from a shell or a script, and notify sends a notification "
            + "when a command finishes. Both are scripts in the app; links to them go in a directory on your PATH."
        if let proposed {
            alert.informativeText = what + "\n\nLinks will be made in \(abbreviate(proposed, home: home))."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Choose Directory…")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        } else {
            alert.informativeText = what + "\n\nNone of ~/bin, ~/.local/bin, /usr/local/bin and /opt/homebrew/bin "
                + "is on your shell's PATH and writable. Choose a directory, and add it to your PATH if it isn't there."
            alert.addButton(withTitle: "Choose Directory…")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        }
        alert.beginSheetModal(for: window) { response in
            switch (proposed, response) {
            case (.some(let directory), .alertFirstButtonReturn):
                install(into: directory, onPath: true, on: window)
            case (.some, .alertSecondButtonReturn), (.none, .alertFirstButtonReturn):
                choose(on: window, path: path)
            default:
                break
            }
        }
    }

    private static func choose(on window: NSWindow, path: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Install Here"
        panel.message = "Choose a directory on your PATH for the dmucode and notify commands."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // After the alert's sheet has gone, or the panel won't attach.
        DispatchQueue.main.async {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                let directory = url.path
                DispatchQueue.main.async { install(into: directory, onPath: path.contains(directory), on: window) }
            }
        }
    }

    private static func install(into directory: String, onPath: Bool, on window: NSWindow) {
        let home = NSHomeDirectory()
        let alert = NSAlert()
        do {
            let results = try CommandLineTools.install(sources, into: directory)
            alert.alertStyle = .informational
            alert.messageText = "Commands installed"
            var lines = results.map { name, outcome in
                let link = abbreviate(directory + "/" + name, home: home)
                switch outcome {
                case .linked: return "\(link) links to the app."
                case .alreadyLinked: return "\(link) already links to the app."
                case .replaced(let previous): return "\(link) now links to this app instead of \(abbreviate(previous, home: home))."
                case .inTheWay: return "\(link) exists and isn't a link to dmucode; left alone."
                }
            }
            if results.contains(where: { $0.outcome == .inTheWay }) { alert.messageText = "Commands partly installed" }
            if !onPath {
                lines.append("\(abbreviate(directory, home: home)) isn't on your shell's PATH; add it to use the commands by name.")
            }
            lines.append("The links follow the app in \(abbreviate(Bundle.main.bundlePath, home: home)).")
            alert.informativeText = lines.joined(separator: "\n\n")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the commands"
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
