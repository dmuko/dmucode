import Foundation
import Testing
@testable import dmucode

struct DefaultsMigrationTests {
    private let defaults = UserDefaults.standard
    private let old = "dmucode.tests.old-\(UUID().uuidString)"
    private let new = "dmucode.tests.new-\(UUID().uuidString)"

    /// Emptying a domain leaves its (empty) plist behind; remove that too.
    private func cleanUp() {
        for domain in [old, new] {
            defaults.removePersistentDomain(forName: domain)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(domain).plist")
            try? FileManager.default.removeItem(at: plist)
        }
    }

    @Test func copiesTheOldSettingsOnce() {
        defer { cleanUp() }
        defaults.setPersistentDomain(["lastSessionName": "Main", "commandBarHistory": ["ls"]], forName: old)

        #expect(DefaultsMigration.run(from: old, into: new))
        #expect(defaults.persistentDomain(forName: new)?["lastSessionName"] as? String == "Main")
        #expect(defaults.persistentDomain(forName: new)?["commandBarHistory"] as? [String] == ["ls"])

        // Later changes under the old id don't overwrite the new settings.
        defaults.setPersistentDomain(["lastSessionName": "Other"], forName: old)
        #expect(!DefaultsMigration.run(from: old, into: new))
        #expect(defaults.persistentDomain(forName: new)?["lastSessionName"] as? String == "Main")
    }

    @Test func nothingToCopy() {
        defer { cleanUp() }
        #expect(!DefaultsMigration.run(from: old, into: new))
        #expect(defaults.persistentDomain(forName: new) == nil)
    }

    @Test func keepsExistingNewSettings() {
        defer { cleanUp() }
        defaults.setPersistentDomain(["lastSessionName": "Old"], forName: old)
        defaults.setPersistentDomain(["lastSessionName": "New"], forName: new)
        #expect(!DefaultsMigration.run(from: old, into: new))
        #expect(defaults.persistentDomain(forName: new)?["lastSessionName"] as? String == "New")
    }
}
