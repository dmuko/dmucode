import Foundation

/// A working tree's state, shown on a tab: branch, changes, ahead/behind.
struct GitStatus: Equatable {
    /// Branch name, or a short commit id when detached.
    let branch: String
    let changed: Int
    let untracked: Int
    let conflicted: Int
    let ahead: Int
    let behind: Int

    var isDirty: Bool { changed + untracked + conflicted > 0 }

    /// Parses `git status --porcelain=v2 --branch`.
    static func parse(_ output: String) -> GitStatus? {
        var head: String?, oid = ""
        var changed = 0, untracked = 0, conflicted = 0, ahead = 0, behind = 0
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            switch fields.first {
            case "#":
                guard fields.count >= 3 else { continue }
                switch fields[1] {
                case "branch.oid": oid = String(fields[2])
                case "branch.head": head = String(fields[2])
                case "branch.ab" where fields.count >= 4:
                    ahead = Int(fields[2].dropFirst()) ?? 0
                    behind = Int(fields[3].dropFirst()) ?? 0
                default: break
                }
            case "1", "2": changed += 1
            case "u": conflicted += 1
            case "?": untracked += 1
            default: break
            }
        }
        guard let head else { return nil }
        let branch = head == "(detached)" ? String(oid.prefix(7)) : head
        return GitStatus(branch: branch, changed: changed, untracked: untracked,
                         conflicted: conflicted, ahead: ahead, behind: behind)
    }
}

/// Git status per directory, for the tabs of the selected session. Updated
/// when the set of directories changes and every few seconds after that,
/// since edits to files send no event. Directories outside a repository map
/// to nil. Published state is touched on the main thread.
final class GitStatusStore: ObservableObject {
    @Published private(set) var statuses: [String: GitStatus] = [:]

    private let git: String?
    private let queue = DispatchQueue(label: "dmucode.git")
    private var paths: Set<String> = []
    private var timer: Timer?
    private var running = false

    init() {
        git = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The directories to keep up to date; others are dropped.
    func track(_ newPaths: Set<String>) {
        guard newPaths != paths else { return }
        paths = newPaths
        statuses = statuses.filter { newPaths.contains($0.key) }
        update()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        }
    }

    private func update() {
        guard let git, !running, !paths.isEmpty else { return }
        running = true
        let paths = self.paths
        queue.async {
            var results: [String: GitStatus] = [:]
            for path in paths {
                results[path] = Self.status(git: git, path: path)
            }
            DispatchQueue.main.async {
                self.running = false
                // Paths dropped meanwhile stay dropped.
                let current = results.filter { self.paths.contains($0.key) }
                if current != self.statuses { self.statuses = current }
            }
        }
    }

    private static func status(git: String, path: String) -> GitStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        // --no-optional-locks: don't take index.lock behind the user's back.
        process.arguments = ["--no-optional-locks", "-C", path, "status", "--porcelain=v2", "--branch"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil } // not a repository
        return GitStatus.parse(String(decoding: data, as: UTF8.self))
    }
}
