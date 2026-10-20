import Foundation
import Testing
@testable import dmucodeCore

/// The polling and its pausing, with a fake timer and runner: nothing waits
/// for real seconds or runs the real tool.
struct GitStatusStoreTests {
    private final class Harness: @unchecked Sendable {
        /// Both the work and the main-thread hop of the store run here.
        let queue = DispatchQueue(label: "test.status")
        let lock = NSLock()
        private var _runs: [String] = []
        private(set) var timers: [Int: () -> Void] = [:]
        private(set) var scheduled = 0
        private(set) var cancelled = 0
        /// Blocks the runner until signalled, to test overlapping updates.
        var gate: DispatchSemaphore?
        let hasTool: Bool

        init(hasTool: Bool = true) { self.hasTool = hasTool }

        var runs: [String] { lock.withLock { _runs } }
        var activeTimers: Int { timers.count }

        lazy var store = GitStatusStore(
            git: hasTool ? "/fake/git" : nil, interval: 3,
            schedule: { [unowned self] _, fire in
                let id = scheduled
                scheduled += 1
                timers[id] = fire
                return { [unowned self] in cancelled += 1; timers[id] = nil }
            },
            runner: { [unowned self] _, path in
                gate?.wait()
                lock.withLock { _runs.append(path) }
                return GitStatus(branch: "main", changed: 0, untracked: 0, conflicted: 0, ahead: 0, behind: 0)
            },
            workQueue: queue, mainQueue: queue)

        /// Lets updates (work, delivery, a rerun) finish.
        func settle() {
            for _ in 0..<6 { queue.sync {} }
        }

        func tick() { timers.values.forEach { $0() } }
    }

    @Test func updatesWhenPathsChangeAndOnEveryTick() {
        let h = Harness()
        h.store.track(["/a"])
        h.settle()
        #expect(h.runs == ["/a"])
        #expect(h.store.statuses.keys.sorted() == ["/a"])
        #expect(h.activeTimers == 1)

        h.tick(); h.settle()
        h.tick(); h.settle()
        #expect(h.runs == ["/a", "/a", "/a"])

        // The same paths again: nothing to do.
        h.store.track(["/a"])
        h.settle()
        #expect(h.runs.count == 3)
        #expect(h.scheduled == 1)
    }

    @Test func inactiveStopsTheTimer() {
        let h = Harness()
        h.store.track(["/a"])
        h.settle()
        h.store.setActive(false)
        #expect(h.store.isPaused)
        #expect(h.activeTimers == 0)
        #expect(h.cancelled == 1)
        h.settle()
        #expect(h.runs.count == 1)
    }

    @Test func activeAgainUpdatesAtOnceAndRestartsTheTimer() {
        let h = Harness()
        h.store.track(["/a"])
        h.settle()
        h.store.setActive(false)
        h.store.setActive(true)
        h.settle()
        #expect(!h.store.isPaused)
        #expect(h.runs == ["/a", "/a"])
        #expect(h.activeTimers == 1)
        #expect(h.scheduled == 2)
    }

    @Test func repeatedSignalsDoNothing() {
        let h = Harness()
        h.store.track(["/a"])
        h.settle()
        h.store.setActive(true) // already active
        h.store.setActive(false)
        h.store.setActive(false)
        h.store.setActive(true)
        h.store.setActive(true)
        h.settle()
        #expect(h.runs.count == 2)
        #expect(h.scheduled == 2)
        #expect(h.cancelled == 1)
    }

    @Test func newPathsWhilePausedGetOneUpdateButNoTimer() {
        let h = Harness()
        h.store.setActive(false)
        h.store.track(["/a"])
        h.settle()
        #expect(h.runs == ["/a"])
        #expect(h.scheduled == 0)

        h.store.track(["/a", "/b"])
        h.settle()
        #expect(h.runs.count == 1 + 2)
        #expect(h.scheduled == 0)

        // Resuming starts the timer.
        h.store.setActive(true)
        h.settle()
        #expect(h.activeTimers == 1)
    }

    @Test func resumingWithoutPathsStartsNothing() {
        let h = Harness()
        h.store.setActive(false)
        h.store.setActive(true)
        h.settle()
        #expect(h.runs.isEmpty)
        #expect(h.scheduled == 0)
    }

    @Test func resumingDuringARunUpdatesAfterIt() {
        let h = Harness()
        h.gate = DispatchSemaphore(value: 0)
        h.store.track(["/a"]) // starts a run, held at the gate
        h.store.setActive(false)
        h.store.setActive(true) // asks for another while one runs
        h.gate?.signal()
        h.gate?.signal()
        h.settle()
        #expect(h.runs == ["/a", "/a"])
    }

    @Test func noToolMeansNoWork() {
        let h = Harness(hasTool: false)
        h.store.track(["/a"])
        h.settle()
        #expect(h.runs.isEmpty)
        #expect(h.store.statuses.isEmpty)
    }
}
