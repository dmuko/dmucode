import Foundation
import Testing
@testable import dmucodeCore

struct TmuxRunTests {
    /// A process that fills stderr past the pipe buffer (64 KB) before
    /// exiting would hang `run` if it read stdout to the end first. The call
    /// runs on another thread with a deadline, so a regression fails the
    /// test instead of hanging it (a time limit can't stop a blocked thread).
    @Test func largeStderrDoesNotDeadlock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmucode-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-tmux")
        try """
        #!/bin/sh
        head -c 200000 /dev/zero | tr '\\0' 'e' >&2
        echo out
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let tmux = Tmux(executable: script.path, socketName: nil)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[TmuxSession], Error>?
        Thread {
            result = Result { try tmux.listSessions() }
            done.signal()
        }.start()
        try #require(done.wait(timeout: .now() + 10) == .success, "Tmux.run deadlocked")
        #expect(throws: TmuxError.self) { try result?.get() }
        if case .failure(let error as TmuxError) = result {
            #expect(error.description.count == 200_000)
        }
    }
}
