import Foundation
import Testing
@testable import dmucodeCore

struct FullDiskAccessTests {
    @Test func promptsOnlyWhileMissingAndWanted() {
        var config = AppConfig()
        #expect(FullDiskAccess.shouldPrompt(config: config, dismissed: false, granted: false))
        #expect(!FullDiskAccess.shouldPrompt(config: config, dismissed: false, granted: true))
        #expect(!FullDiskAccess.shouldPrompt(config: config, dismissed: true, granted: false))
        config.fullDiskAccessPrompt = false
        #expect(!FullDiskAccess.shouldPrompt(config: config, dismissed: false, granted: false))
    }

    /// A home without the TCC database reads as no access; the real check
    /// depends on the machine, so only its shape is tested.
    @Test func aMissingDatabaseMeansNoAccess() {
        #expect(!FullDiskAccess.isGranted(probing: ["/nonexistent/TCC.db"]))
    }

    /// A missing path is skipped rather than read as no access: macOS 27
    /// has no per-user TCC database.
    @Test func missingPathsAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let readable = dir.appendingPathComponent("readable").path
        let refused = dir.appendingPathComponent("refused").path
        FileManager.default.createFile(atPath: readable, contents: Data())
        FileManager.default.createFile(atPath: refused, contents: Data(), attributes: [.posixPermissions: 0])

        #expect(FullDiskAccess.isGranted(probing: ["/nonexistent/TCC.db", readable]))
        #expect(!FullDiskAccess.isGranted(probing: ["/nonexistent/TCC.db", refused, readable]))
    }

    @Test func probesTheUserDatabaseFirst() {
        #expect(FullDiskAccess.probePaths(home: "/Users/x").first
            == "/Users/x/Library/Application Support/com.apple.TCC/TCC.db")
    }

    @Test func settingsURLOpensThePane() {
        // Foundation versions differ on what the query of a host-less URL is.
        #expect(FullDiskAccess.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
