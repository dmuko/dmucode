import Foundation

/// Runs a command-line tool to completion and collects its output. Calls
/// block, so run them off the main thread.
enum Subprocess {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(
        executable: String, arguments: [String], input: String? = nil, environment: [String: String]
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        try process.run()
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Both pipes at once: reading one to the end first would deadlock
        // once the other fills its buffer (64 KB) and the process blocks.
        // A thread of its own, not a dispatch queue: a blocking read must not
        // depend on a free worker thread (CI runners have few).
        var stderr = Data()
        let stderrRead = DispatchSemaphore(value: 0)
        Thread {
            stderr = err.fileHandleForReading.readDataToEndOfFile()
            stderrRead.signal()
        }.start()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        stderrRead.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self))
    }
}
