import Foundation
import Testing
@testable import dmucode

struct SidebarLayoutTests {
    private func sessions(_ names: String...) -> [TmuxSession] {
        names.map { TmuxSession(id: "$" + $0, name: $0, windows: [], attachedClients: 0) }
    }

    /// The rows as the debug hook prints them: "#Group" for a header.
    private func rows(_ layout: SidebarLayout, _ running: [TmuxSession]) -> [String] {
        layout.rows(for: running).map { row in
            switch row {
            case .group(let name): return "#" + name
            case .session(let session): return session.name
            }
        }
    }

    /// Ungrouped a, b, c; group Agents with x, y.
    private func sample() -> SidebarLayout {
        var layout = SidebarLayout()
        layout.include(["a", "b", "c", "x", "y"])
        layout.addGroup("Agents")
        layout.setGroup("Agents", ofSession: "x")
        layout.setGroup("Agents", ofSession: "y")
        return layout
    }

    private var all: [TmuxSession] { sessions("a", "b", "c", "x", "y") }

    // MARK: Order

    @Test func newNamesGoToTheEndOfTheUngrouped() {
        var layout = sample()
        layout.include(["c", "new"])
        #expect(rows(layout, all + sessions("new")) == ["a", "b", "c", "new", "#Agents", "x", "y"])
    }

    @Test func rowsIncludeUnknownSessionsWithoutStoringThem() {
        let layout = sample()
        #expect(rows(layout, sessions("a", "z")) == ["a", "z", "#Agents"])
        #expect(!layout.entries.contains(.session("z")))
    }

    @Test func sessionsThatAreNotRunningKeepTheirPlace() {
        let layout = sample()
        #expect(rows(layout, sessions("a", "c", "y")) == ["a", "c", "#Agents", "y"])
        #expect(rows(layout, all) == ["a", "b", "c", "#Agents", "x", "y"])
    }

    @Test func sortedFollowsTheRows() {
        #expect(sample().sorted(sessions("y", "c", "a")).map(\.name) == ["a", "c", "y"])
    }

    // MARK: Dragging sessions

    @Test func moveUp() {
        var layout = sample()
        layout.move(layout.rows(for: all), from: 2, to: 0)
        #expect(rows(layout, all) == ["c", "a", "b", "#Agents", "x", "y"])
    }

    @Test func moveDownWithinAGroup() {
        var layout = sample()
        layout.move(layout.rows(for: all), from: 4, to: 6)
        #expect(rows(layout, all) == ["a", "b", "c", "#Agents", "y", "x"])
    }

    @Test func dropBelowAHeaderJoinsTheGroup() {
        var layout = sample()
        layout.move(layout.rows(for: all), from: 0, to: 4)
        #expect(rows(layout, all) == ["b", "c", "#Agents", "a", "x", "y"])
        #expect(layout.group(ofSession: "a") == "Agents")
    }

    @Test func dropAtTheEndJoinsTheLastGroup() {
        var layout = sample()
        layout.move(layout.rows(for: all), from: 1, to: 6)
        #expect(rows(layout, all) == ["a", "c", "#Agents", "x", "y", "b"])
    }

    @Test func dropAboveTheFirstHeaderLeavesTheGroup() {
        var layout = sample()
        layout.move(layout.rows(for: all), from: 5, to: 3)
        #expect(rows(layout, all) == ["a", "b", "c", "y", "#Agents", "x"])
        #expect(layout.group(ofSession: "y") == nil)
    }

    @Test func dropOnItsOwnPlaceChangesNothing() {
        var layout = sample()
        let before = layout
        layout.move(layout.rows(for: all), from: 1, to: 1)
        layout.move(layout.rows(for: all), from: 1, to: 2)
        #expect(layout == before)
    }

    @Test func notRunningSessionsStayInTheirGroup() {
        // y isn't running; moving x out of Agents leaves y there.
        var layout = sample()
        let running = sessions("a", "b", "c", "x")
        layout.move(layout.rows(for: running), from: 4, to: 0)
        #expect(rows(layout, running) == ["x", "a", "b", "c", "#Agents"])
        #expect(layout.group(ofSession: "y") == "Agents")
    }

    // MARK: Dragging groups

    /// sample() plus group Work with a; rows: b, c, #Agents, x, y, #Work, a.
    private func twoGroups() -> SidebarLayout {
        var layout = sample()
        layout.addGroup("Work")
        layout.setGroup("Work", ofSession: "a")
        return layout
    }

    @Test func groupMovesWithItsSessions() {
        var layout = twoGroups()
        layout.move(layout.rows(for: all), from: 5, to: 2)
        #expect(rows(layout, all) == ["b", "c", "#Work", "a", "#Agents", "x", "y"])
    }

    @Test func groupDroppedAmongUngroupedBecomesTheFirstGroup() {
        var layout = twoGroups()
        layout.move(layout.rows(for: all), from: 5, to: 0)
        #expect(rows(layout, all) == ["b", "c", "#Work", "a", "#Agents", "x", "y"])
    }

    @Test func groupDroppedInsideAnotherGoesAfterIt() {
        var layout = twoGroups()
        layout.move(layout.rows(for: all), from: 2, to: 6)
        #expect(rows(layout, all) == ["b", "c", "#Work", "a", "#Agents", "x", "y"])
    }

    @Test func groupDroppedOnItsOwnSessionChangesNothing() {
        var layout = twoGroups()
        let before = layout
        layout.move(layout.rows(for: all), from: 2, to: 4)
        #expect(layout == before)
    }

    // MARK: Groups

    @Test func groupNamesAreUnique() {
        var layout = sample()
        let duplicate = layout.addGroup("Agents")
        let added = layout.addGroup("Work")
        let renamedOntoExisting = layout.renameGroup("Work", to: "Agents")
        let renamed = layout.renameGroup("Work", to: "Play")
        #expect(!duplicate && added && !renamedOntoExisting && renamed)
        #expect(layout.groups == ["Agents", "Play"])
    }

    @Test func removingAGroupUngroupsItsSessions() {
        var layout = sample()
        layout.removeGroup("Agents")
        #expect(rows(layout, all) == ["a", "b", "c", "x", "y"])
        #expect(layout.groups == [])
    }

    @Test func setGroupMovesToTheEnd() {
        var layout = sample()
        layout.setGroup("Agents", ofSession: "a")
        #expect(rows(layout, all) == ["b", "c", "#Agents", "x", "y", "a"])
        layout.setGroup(nil, ofSession: "x")
        #expect(rows(layout, all) == ["b", "c", "x", "#Agents", "y", "a"])
        layout.setGroup("Missing", ofSession: "b")
        #expect(layout.group(ofSession: "b") == nil)
    }

    // MARK: Renames and persistence

    @Test func renamedSessionKeepsItsPlace() {
        var layout = sample()
        layout.renameSession("x", to: "claude")
        #expect(rows(layout, sessions("a", "b", "c", "claude", "y")) == ["a", "b", "c", "#Agents", "claude", "y"])
    }

    @Test func renameReplacesTheNewNamesOldPlace() {
        var layout = sample()
        layout.renameSession("y", to: "a")
        #expect(layout.entries == [.session("b"), .session("c"), .group("Agents"), .session("x"), .session("a")])
    }

    @Test func survivesEncoding() throws {
        let layout = twoGroups()
        let decoded = try JSONDecoder().decode(SidebarLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }
}
