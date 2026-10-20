import Foundation

/// A working tree's state, shown on a tab: branch, changes, ahead/behind.
public struct GitStatus: Equatable {
    /// Branch name, or a short commit id when detached.
    public let branch: String
    public let changed: Int
    public let untracked: Int
    public let conflicted: Int
    public let ahead: Int
    public let behind: Int

    public var isDirty: Bool { changed + untracked + conflicted > 0 }

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
/// since edits to files send no event. The polling pauses while the app is in
/// the background or its window is hidden (`setActive`) and catches up at
/// once on resuming; new directories still get one update while paused.
/// Directories outside a repository map to nil. Published state is touched on
/// the main thread.
public final class GitStatusStore: ObservableObject {
    /// Starts a repeating timer and returns the function that stops it.
    typealias Schedule = (_ interval: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void
    /// Runs `git status` for a directory (blocking). Arguments: git, path.
    typealias Runner = (String, String) -> GitStatus?

    @Published public private(set) var statuses: [String: GitStatus] = [:]
    /// Polling is suspended; see `setActive`.
    public private(set) var isPaused = false

    private let git: String?
    private let interval: TimeInterval
    private let schedule: Schedule
    private let runner: Runner
    private let workQueue: DispatchQueue
    private let mainQueue: DispatchQueue
    private var paths: Set<String> = []
    private var cancelTimer: (() -> Void)?
    private var running = false
    /// An update was asked for while one was running.
    private var rerun = false

    public convenience init() {
        self.init(git: ExecutableLookup().find("git"), interval: 3, schedule: Self.scheduleTimer,
                  runner: Self.status, workQueue: DispatchQueue(label: "dmucode.git"), mainQueue: .main)
    }

    init(git: String?, interval: TimeInterval, schedule: @escaping Schedule, runner: @escaping Runner,
         workQueue: DispatchQueue, mainQueue: DispatchQueue) {
        self.git = git
        self.interval = interval
        self.schedule = schedule
        self.runner = runner
        self.workQueue = workQueue
        self.mainQueue = mainQueue
    }

    /// The directories to keep up to date; others are dropped.
    public func track(_ newPaths: Set<String>) {
        guard newPaths != paths else { return }
        paths = newPaths
        statuses = statuses.filter { newPaths.contains($0.key) }
        // New directories get a status even while paused, but no timer.
        update()
        if !isPaused { startTimer() }
    }

    /// Whether anyone is looking: false while the app is in the background or
    /// the window is minimized or hidden. Inactive stops the timer; becoming
    /// active again updates at once and restarts it.
    public func setActive(_ active: Bool) {
        guard active == isPaused else { return }
        isPaused = !active
        if active {
            guard !paths.isEmpty else { return }
            update()
            startTimer()
        } else {
            cancelTimer?()
            cancelTimer = nil
        }
    }

    private func startTimer() {
        guard cancelTimer == nil else { return }
        cancelTimer = schedule(interval) { [weak self] in self?.update() }
    }

    private static func scheduleTimer(_ interval: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in fire() }
        // Nothing here is urgent; let the system batch wakeups.
        timer.tolerance = interval / 3
        return { timer.invalidate() }
    }

    private func update() {
        guard let git, !paths.isEmpty else { return }
        guard !running else { rerun = true; return }
        running = true
        let paths = self.paths
        workQueue.async {
            var results: [String: GitStatus] = [:]
            for path in paths {
                results[path] = self.runner(git, path)
            }
            self.mainQueue.async {
                self.running = false
                // Paths dropped meanwhile stay dropped.
                let current = results.filter { self.paths.contains($0.key) }
                if current != self.statuses { self.statuses = current }
                // The paths changed, or polling resumed, during the run.
                if self.rerun {
                    self.rerun = false
                    if !self.isPaused { self.update() }
                }
            }
        }
    }

    static func status(git: String, path: String) -> GitStatus? {
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
