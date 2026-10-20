import Foundation
import Testing
@testable import dmucodeCore

/// The pipeline with an injected write function, so no tmux is involved.
struct ControlCommandPipelineTests {
    private struct WriteFailed: Error {}

    /// Collects what a `write` function was given and what the callbacks got.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _failures: [String: String] = [:]
        private var _popped: [String] = []

        var lines: [String] { lock.withLock { _lines } }
        var failures: [String: String] { lock.withLock { _failures } }

        func wrote(_ data: Data) { lock.withLock { _lines.append(String(decoding: data, as: UTF8.self)) } }

        /// A reply callback tagged `tag`: records a failure, or the tag when
        /// it is invoked with a success.
        func reply(_ tag: String) -> ControlCommandPipeline.Reply {
            { result in
                self.lock.withLock {
                    switch result {
                    case .success: self._popped.append(tag)
                    case .failure(let error): self._failures[tag] = error.description
                    }
                }
            }
        }

        var popped: [String] { lock.withLock { _popped } }
    }

    private let callbacks = DispatchQueue(label: "test.callbacks")

    private func pipeline(_ write: @escaping (Data) throws -> Void) -> ControlCommandPipeline {
        ControlCommandPipeline(callbackQueue: callbacks, write: write)
    }

    /// Waits until `condition` holds; the pipeline's queues are asynchronous.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func repliesMatchWritesInOrderUnderConcurrentSends() async {
        let recorder = Recorder()
        let pipeline = pipeline(recorder.wrote)
        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { i in
            pipeline.send(Data("\(i)\n".utf8), reply: recorder.reply("\(i)"))
        }
        #expect(await eventually { recorder.lines.count == count })

        // The n-th reply tmux sends belongs to the n-th line written.
        for _ in recorder.lines {
            pipeline.popReply()?(.success([]))
        }
        #expect(recorder.popped == recorder.lines.map { String($0.dropLast()) })
        #expect(pipeline.popReply() == nil)
    }

    @Test func failedWriteFailsItsCallbackAndLeavesNoStaleEntry() async {
        let recorder = Recorder()
        var calls = 0
        let pipeline = pipeline { data in
            calls += 1
            if calls == 2 { throw WriteFailed() }
            recorder.wrote(data)
        }
        pipeline.send(Data("a\n".utf8), reply: recorder.reply("a"))
        pipeline.send(Data("b\n".utf8), reply: recorder.reply("b"))
        pipeline.send(Data("c\n".utf8), reply: recorder.reply("c"))

        // b fails, and so does c: after a failed write the stream may hold
        // half a command, so nothing more is written.
        #expect(await eventually { recorder.failures.count == 2 })
        #expect(recorder.failures.keys.sorted() == ["b", "c"])
        #expect(recorder.lines == ["a\n"])

        // Only a is still waiting, so the next reply is a's.
        pipeline.popReply()?(.success([]))
        #expect(recorder.popped == ["a"])
        #expect(pipeline.popReply() == nil)
    }

    @Test func sendNeverBlocksOnAStuckWrite() async {
        let recorder = Recorder()
        let release = DispatchSemaphore(value: 0)
        let pipeline = pipeline { data in
            release.wait()
            recorder.wrote(data)
        }
        // Each of these would block forever if send waited for its write.
        for tag in ["a", "b", "c"] {
            pipeline.send(Data("\(tag)\n".utf8), reply: recorder.reply(tag))
        }

        // The state the heartbeat reads is available, and shows the age of
        // the oldest command although nothing was written.
        let state = pipeline.heartbeatState()
        #expect(state.oldest != nil)
        #expect(!state.idle)

        // finish returns at once with every waiting callback, in order.
        let replies = pipeline.finish()
        #expect(replies?.count == 3)
        #expect(pipeline.finish() == nil)
        #expect(pipeline.heartbeatState().oldest == nil)
        #expect(!pipeline.heartbeatState().idle)

        // Unblocking lets the write in flight complete; the queued ones are
        // dropped unwritten, as their callbacks are already failed.
        for _ in 0..<3 { release.signal() }
        let drained = DispatchSemaphore(value: 0)
        pipeline.afterWrites { drained.signal() }
        drained.wait()
        #expect(recorder.lines.count <= 1)
    }

    @Test func sendAfterFinishFails() async {
        let recorder = Recorder()
        let pipeline = pipeline(recorder.wrote)
        _ = pipeline.finish()
        pipeline.send(Data("a\n".utf8), reply: recorder.reply("a"))
        #expect(await eventually { recorder.failures["a"] == "tmux control client has exited" })
        #expect(recorder.lines.isEmpty)
    }

    @Test func heartbeatStateTracksPendingCommands() async {
        let recorder = Recorder()
        let pipeline = pipeline(recorder.wrote)
        #expect(pipeline.heartbeatState().idle)
        #expect(pipeline.heartbeatState().oldest == nil)

        pipeline.send(Data("a\n".utf8), reply: nil)
        #expect(!pipeline.heartbeatState().idle)
        #expect(pipeline.heartbeatState().oldest != nil)

        _ = pipeline.popReply()
        #expect(pipeline.heartbeatState().idle)
    }

    @Test func afterWritesRunsBehindQueuedWrites() async {
        let recorder = Recorder()
        let pipeline = pipeline(recorder.wrote)
        pipeline.send(Data("a\n".utf8), reply: nil)
        var linesWhenRun: [String]?
        let done = DispatchSemaphore(value: 0)
        pipeline.afterWrites {
            linesWhenRun = recorder.lines
            done.signal()
        }
        done.wait()
        #expect(linesWhenRun == ["a\n"])
    }
}
