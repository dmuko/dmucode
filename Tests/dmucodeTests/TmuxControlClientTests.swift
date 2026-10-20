import Foundation
import Testing
@testable import dmucodeCore

private let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Drives the client against a real tmux server of its own (`-L` socket,
/// `-f /dev/null`), never the default server. Skipped without tmux.
@Suite(.enabled(if: tmuxPath != nil, "tmux is not installed"))
struct TmuxControlClientTests {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ value: T) { _value = value }
        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
        func update(_ change: (inout T) -> Void) { lock.withLock { change(&_value) } }
    }

    private func run(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath!)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func queriesAndNotificationsOverARealServer() async throws {
        let socket = "dmucode-test-\(UUID().uuidString.prefix(8))"
        try run(["-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "one"])
        defer {
            try? run(["-L", socket, "kill-server"])
            // tmux leaves the socket file behind when it is killed with clients attached.
            try? FileManager.default.removeItem(atPath: "/private/tmp/tmux-\(getuid())/\(socket)")
        }

        let tmux = Tmux(executable: tmuxPath!, socketName: socket)
        let client = try TmuxControlClient(tmux: tmux, sessionID: "one")
        let notifications = Box<[String]>([])
        client.onNotification = { name, _ in notifications.update { $0.append(name) } }

        // Many commands queued at once: each reply reaches its own callback.
        let replies = Box<[Int: [String]]>([:])
        let count = 50
        for i in 0..<count {
            client.send(["display-message", "-p", "n\(i)"]) { result in
                if case .success(let lines) = result { replies.update { $0[i] = lines } }
            }
        }
        #expect(await eventually { replies.value.count == count })
        for i in 0..<count { #expect(replies.value[i] == ["n\(i)"]) }

        let sessions = Box<[String]?>(nil)
        client.listSessions { result in
            sessions.value = (try? result.get())?.map(\.name)
        }
        #expect(await eventually { sessions.value != nil })
        #expect(sessions.value == ["one"])

        try run(["-L", socket, "new-session", "-d", "-s", "two"])
        #expect(await eventually { notifications.value.contains("%sessions-changed") })

        // A command that fails in tmux still gets its own reply.
        let failure = Box<String?>(nil)
        client.send(["no-such-command"]) { result in
            if case .failure(let error) = result { failure.value = error.description }
        }
        #expect(await eventually { failure.value != nil })

        // After the server is gone the client reports it and fails new commands.
        let exited = Box(false)
        client.onExit = { exited.value = true }
        try run(["-L", socket, "kill-server"])
        #expect(await eventually { exited.value })
        let late = Box<String?>(nil)
        client.send(["display-message", "-p", "late"]) { result in
            if case .failure(let error) = result { late.value = error.description }
        }
        #expect(await eventually { late.value != nil })
        client.close()
    }
}
