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
        // Foundation versions differ on what the query of a host-less URL is.
        #expect(FullDiskAccess.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
