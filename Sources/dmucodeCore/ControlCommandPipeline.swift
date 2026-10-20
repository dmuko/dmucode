import Foundation

/// The outgoing half of the control-mode connection: the commands written to
/// tmux's stdin and the reply callbacks waiting for their answers, apart from
/// the process.
///
/// `send` only records state under a lock and hands the write to a serial
/// queue, so it never blocks on I/O: if the server stops reading stdin and the
/// pipe fills, only that queue waits. The lock never covers I/O, so the
/// heartbeat and the reader keep working and can still notice the stall.
///
/// Replies arrive in the order commands were written. The pending entry is
/// appended and the write queued in one critical section, so the order of the
/// entries is the order of the writes.
final class ControlCommandPipeline: @unchecked Sendable {
    typealias Reply = (Result<[String], TmuxError>) -> Void

    private struct Entry {
        let id: UInt64
        /// When the command was queued, not when it was written: a write stuck
        /// behind a full pipe is as overdue as a reply that never comes.
        let sent: SuspendingClock.Instant
        let reply: Reply
    }

    private let write: (Data) throws -> Void
    private let callbackQueue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "dmucode.tmux-control.write")

    // Guards the state below; held only for in-memory work.
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var nextID: UInt64 = 0
    private var finished = false
    private var writeError: Error?

    /// `write` runs on the pipeline's serial write queue and may block.
    /// Failed callbacks run on `callbackQueue`.
    init(callbackQueue: DispatchQueue = .main, write: @escaping (Data) throws -> Void) {
        self.write = write
        self.callbackQueue = callbackQueue
    }

    /// Queues `line` for writing and registers `reply` for its answer; never
    /// blocks. On success the reader finds `reply` with `popReply`. It fails
    /// on the callback queue if the pipeline has finished or the write fails.
    func send(_ line: Data, reply: Reply?) {
        let reply = reply ?? { _ in }
        lock.lock()
        if finished {
            lock.unlock()
            fail(reply, TmuxError(description: "tmux control client has exited"))
            return
        }
        let id = nextID
        nextID += 1
        pending.append(Entry(id: id, sent: .now, reply: reply))
        // Inside the lock, so the queue order is the pending order.
        writeQueue.async { [self] in perform(id, line) }
        lock.unlock()
    }

    private func perform(_ id: UInt64, _ line: Data) {
        lock.lock()
        let earlier = writeError
        let wanted = pending.contains { $0.id == id }
        lock.unlock()
        // Finished meanwhile: the command is already failed, don't write it.
        guard wanted else { return }

        do {
            // After a failed write the stream may hold half a command, so
            // nothing more goes out.
            if let earlier { throw earlier }
            try write(line)
        } catch {
            lock.lock()
            if writeError == nil { writeError = error }
            let entry = remove(id)
            lock.unlock()
            // No stale entry stays to take a later command's reply.
            if let entry { fail(entry.reply, TmuxError(description: "\(error)")) }
        }
    }

    /// The callback of the oldest command still waiting for its reply.
    func popReply() -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst().reply
    }

    /// What the heartbeat needs: when the oldest unanswered command was
    /// queued, and whether nothing is pending (false once finished).
    func heartbeatState() -> (oldest: SuspendingClock.Instant?, idle: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return finished ? (nil, false) : (pending.first?.sent, pending.isEmpty)
    }

    /// Ends the pipeline, once. Returns the callbacks still waiting, for the
    /// caller to fail, or nil if it had already finished. Commands still in
    /// the write queue are dropped unwritten.
    func finish() -> [Reply]? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        let replies = pending.map(\.reply)
        pending.removeAll()
        return replies
    }

    /// Runs `work` on the write queue after the commands queued so far, so
    /// closing the pipe can't cut a write short or race its descriptor.
    func afterWrites(_ work: @escaping () -> Void) {
        writeQueue.async(execute: work)
    }

    // Caller holds the lock.
    private func remove(_ id: UInt64) -> Entry? {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: index)
    }

    private func fail(_ reply: @escaping Reply, _ error: TmuxError) {
        callbackQueue.async { reply(.failure(error)) }
    }
}
