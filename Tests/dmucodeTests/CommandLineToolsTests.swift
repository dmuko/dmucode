import Foundation
import Testing
@testable import dmucodeCore

struct CommandLineToolsTests {
    private let home = "/Users/alice"

    private func proposed(path: [String], state: [String: CommandLineTools.DirectoryState]) -> String? {
        CommandLineTools.proposedDirectory(path: path, home: home, state: { state[$0] ?? .missing })
    }

    @Test func prefersTheUsersOwnDirectoriesOnThePath() {
        let all = ["/opt/homebrew/bin", "/usr/local/bin", "/Users/alice/.local/bin", "/Users/alice/bin"]
        #expect(proposed(path: all, state: ["/Users/alice/bin": .writable]) == "/Users/alice/bin")
        // Missing under home: it will be created. Elsewhere it won't.
        #expect(proposed(path: all, state: [:]) == "/Users/alice/bin")
        #expect(proposed(path: ["/usr/local/bin", "/Users/alice/.local/bin"], state: [:]) == "/Users/alice/.local/bin")
        #expect(proposed(path: ["/usr/local/bin"], state: [:]) == nil)
        #expect(proposed(path: ["/usr/local/bin"], state: ["/usr/local/bin": .writable]) == "/usr/local/bin")
        #expect(proposed(path: ["/usr/local/bin", "/opt/homebrew/bin"],
                         state: ["/usr/local/bin": .readOnly, "/opt/homebrew/bin": .writable]) == "/opt/homebrew/bin")
    }

    @Test func onlyDirectoriesOnThePathCount() {
        #expect(proposed(path: [], state: ["/Users/alice/bin": .writable]) == nil)
        #expect(proposed(path: ["/Users/alice/bin"], state: ["/Users/alice/bin": .notADirectory]) == nil)
    }

    @Test func linksReplacesOldLinksAndLeavesOtherFilesAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clitools-" + UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        let app = root + "/dmucode.app/Contents/Resources/bin"
        let old = root + "/old/dmucode.app/Contents/Resources/bin"
        for dir in [app, old] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for name in CommandLineTools.names { fm.createFile(atPath: dir + "/" + name, contents: Data()) }
        }
        let sources = CommandLineTools.names.map { app + "/" + $0 }
        let bin = root + "/home/bin" // doesn't exist yet

        var results = try CommandLineTools.install(sources, into: bin)
        #expect(results.map(\.outcome) == [.linked, .linked])
        #expect(try fm.destinationOfSymbolicLink(atPath: bin + "/notify") == app + "/notify")

        results = try CommandLineTools.install(sources, into: bin)
        #expect(results.map(\.outcome) == [.alreadyLinked, .alreadyLinked])

        // A link to another copy of the app is repointed; anything else stays.
        try fm.removeItem(atPath: bin + "/dmucode")
        try fm.createSymbolicLink(atPath: bin + "/dmucode", withDestinationPath: old + "/dmucode")
        try fm.removeItem(atPath: bin + "/notify")
        fm.createFile(atPath: bin + "/notify", contents: Data("#!/bin/sh\n".utf8))
        results = try CommandLineTools.install(sources, into: bin)
        #expect(results.map(\.outcome) == [.replaced(previous: old + "/dmucode"), .inTheWay])
        #expect(try fm.destinationOfSymbolicLink(atPath: bin + "/dmucode") == app + "/dmucode")
        #expect(try String(contentsOfFile: bin + "/notify", encoding: .utf8) == "#!/bin/sh\n")

        try fm.removeItem(atPath: bin + "/notify")
        try fm.createSymbolicLink(atPath: bin + "/notify", withDestinationPath: "/usr/bin/true")
        results = try CommandLineTools.install(sources, into: bin)
        #expect(results.map(\.outcome) == [.alreadyLinked, .inTheWay])
    }

    @Test func directoryState() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clistate-" + UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/file", contents: Data())
        #expect(CommandLineTools.state(of: root) == .writable)
        #expect(CommandLineTools.state(of: root + "/nope") == .missing)
        #expect(CommandLineTools.state(of: root + "/file") == .notADirectory)
        #expect(CommandLineTools.state(of: "/usr/bin") == .readOnly)
    }

    @Test func pathOutputTakesTheLastPathLikeLine() {
        #expect(ExecutableLookup.parsePathOutput("Welcome!\n/Users/alice/bin:/usr/local/bin:relative:/usr/bin\n")
                == ["/Users/alice/bin", "/usr/local/bin", "/usr/bin"])
        #expect(ExecutableLookup.parsePathOutput("banner only\n") == nil)
    }
}
