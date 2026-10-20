import Foundation
import Testing
@testable import dmucodeCore

/// The stored format, its migration and the pruning of long-unseen names.
struct SidebarLayoutStorageTests {
    private let day: TimeInterval = 24 * 60 * 60
    /// Near the real clock, which `setGroup` and `renameSession` stamp with.
    private let t0 = Date()

    /// The unversioned format as shipped before version 2.
    private let legacyJSON = """
    {"entries":[{"session":{"_0":"a"}},{"session":{"_0":"b"}},\
    {"group":{"_0":"Agents"}},{"session":{"_0":"x"}},{"session":{"_0":"y"}}]}
    """

    private func names(_ layout: SidebarLayout) -> [String] {
        layout.entries.map { entry in
            switch entry {
            case .group(let name): return "#" + name
            case .session(let name): return name
            }
        }
    }

    /// Ungrouped a, b; group Agents with x, y; all seen at t0.
    private func sample() -> SidebarLayout {
        var layout = SidebarLayout()
        layout.include(["a", "b", "x", "y"], now: t0)
        layout.addGroup("Agents")
        layout.setGroup("Agents", ofSession: "x")
        layout.setGroup("Agents", ofSession: "y")
        return layout
    }

    // MARK: Versions

    @Test func unversionedJSONIsMigrated() {
        let loaded = SidebarLayout.load(from: Data(legacyJSON.utf8))
        #expect(loaded.mayOverwrite)
        #expect(names(loaded.layout) == ["a", "b", "#Agents", "x", "y"])
        #expect(loaded.layout.lastSeen.isEmpty)
    }

    @Test func migratedNamesAreStampedOnFirstPruneNotPruned() {
        let layout = SidebarLayout.load(from: Data(legacyJSON.utf8)).layout
        let pruned = layout.pruned(now: t0)
        #expect(names(pruned) == ["a", "b", "#Agents", "x", "y"])
        #expect(pruned.lastSeen.count == 4)
        #expect(pruned.lastSeen.values.allSatisfy { $0 == t0 })
        // Not seen again: they age from the first load.
        #expect(names(pruned.pruned(now: t0.addingTimeInterval(31 * day))) == [])
    }

    @Test func currentFormatRoundTrips() throws {
        let layout = sample()
        let data = try #require(layout.encoded())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == SidebarLayout.currentVersion)
        let loaded = SidebarLayout.load(from: data)
        #expect(loaded.mayOverwrite)
        #expect(loaded.layout == layout)
        #expect(loaded.layout.lastSeen["x"] == t0)
    }

    @Test func entriesKeepTheirVersionOneEncoding() throws {
        let data = try #require(sample().encoded())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacy = try #require(JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        let legacyEntries = try #require(legacy["entries"] as? [[String: Any]])
        #expect(NSArray(array: entries).isEqual(to: legacyEntries))
    }

    @Test func aNewerVersionYieldsDefaultsAndMustNotBeOverwritten() {
        let future = """
        {"version":99,"entries":[{"session":{"_0":"a"}}],"somethingNew":true}
        """
        let loaded = SidebarLayout.load(from: Data(future.utf8))
        #expect(!loaded.mayOverwrite)
        #expect(loaded.layout == SidebarLayout())
    }

    @Test func unreadableDataYieldsDefaultsThatMayReplaceIt() {
        let loaded = SidebarLayout.load(from: Data("not json".utf8))
        #expect(loaded.mayOverwrite)
        #expect(loaded.layout == SidebarLayout())
        #expect(SidebarLayout.load(from: nil).mayOverwrite)
    }

    // MARK: Last seen

    @Test func includeRenewsStampsOnlyWhenAnHourOld() {
        var layout = SidebarLayout()
        layout.include(["a"], now: t0)
        layout.include(["a"], now: t0.addingTimeInterval(60))
        #expect(layout.lastSeen["a"] == t0)
        layout.include(["a"], now: t0.addingTimeInterval(2 * 60 * 60))
        #expect(layout.lastSeen["a"] == t0.addingTimeInterval(2 * 60 * 60))
    }

    @Test func renameDropsTheOldNamesStamp() {
        var layout = sample()
        layout.renameSession("a", to: "c")
        #expect(layout.lastSeen["a"] == nil)
    }

    // MARK: Pruning

    @Test func prunesAfterThirtyDaysNotBefore() {
        let layout = sample()
        #expect(layout.pruned(now: t0.addingTimeInterval(29 * day)) == layout)
        #expect(names(layout.pruned(now: t0.addingTimeInterval(31 * day))) == [])
    }

    @Test func presentNamesAreNeverPruned() {
        let pruned = sample().pruned(now: t0.addingTimeInterval(100 * day), present: ["b", "y"])
        #expect(names(pruned) == ["b", "#Agents", "y"])
    }

    @Test func includeKeepsAPresentNameAcrossLongGaps() {
        var layout = sample()
        let later = t0.addingTimeInterval(100 * day)
        layout.include(["a"], now: later)
        #expect(names(layout.pruned(now: later, present: ["a"])) == ["a"])
    }

    @Test func prunedNameLeavesItsGroupWhichKeepsTheOthers() {
        var layout = sample()
        layout.include(["x"], now: t0.addingTimeInterval(20 * day))
        let pruned = layout.pruned(now: t0.addingTimeInterval(35 * day))
        #expect(names(pruned) == ["#Agents", "x"])
        #expect(pruned.group(ofSession: "x") == "Agents")
        #expect(pruned.lastSeen.keys.sorted() == ["x"])
    }

    @Test func aGroupWithAllMembersPrunedDisappears() {
        var layout = sample()
        layout.addGroup("Later")
        layout.setGroup("Later", ofSession: "z")
        layout.include(["z"], now: t0.addingTimeInterval(30 * day))
        let pruned = layout.pruned(now: t0.addingTimeInterval(31 * day))
        #expect(names(pruned) == ["#Later", "z"])
    }

    @Test func anEmptyGroupSurvivesPruning() {
        var layout = sample()
        layout.addGroup("Empty")
        let pruned = layout.pruned(now: t0.addingTimeInterval(40 * day))
        #expect(names(pruned) == ["#Empty"])
    }

    @Test func aPrunedNameComesBackAtTheEnd() {
        var layout = sample().pruned(now: t0.addingTimeInterval(40 * day))
        layout.include(["a"], now: t0.addingTimeInterval(41 * day))
        #expect(names(layout) == ["a"])
    }
}
