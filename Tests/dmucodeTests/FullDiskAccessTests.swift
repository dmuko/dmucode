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
        #expect(!FullDiskAccess.isGranted(home: "/nonexistent"))
    }

    @Test func settingsURLOpensThePane() {
        #expect(FullDiskAccess.settingsURL.scheme == "x-apple.systempreferences")
        #expect(FullDiskAccess.settingsURL.query == "Privacy_AllFiles")
    }
}
