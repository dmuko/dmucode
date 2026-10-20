import Foundation
import Testing
@testable import dmucodeCore

struct SessionStoreSelectionTests {
    @Test func selectsTheFirstSessionWhenNothingIsRemembered() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        #expect(h.store.selectedID == "$a")
    }

    @Test func rememberedSessionIsSelectedWhenItAppears() {
        let h = StoreHarness()
        h.defaults.set("b", forKey: "lastSessionName-test")
        h.tmux.sessions = [session("a")]
        h.start()
        #expect(h.store.selectedID == "$a")

        // E.g. restored by tmux-resurrect a moment later.
        h.tmux.sessions = [session("a"), session("b")]
        h.refresh()
        #expect(h.store.selectedID == "$b")
    }

    @Test func automaticPicksDoNotOverwriteTheRememberedName() {
        let h = StoreHarness()
        h.defaults.set("b", forKey: "lastSessionName-test")
        h.tmux.sessions = [session("a")]
        h.start()
        #expect(h.store.selectedID == "$a")
        #expect(h.lastSessionName == "b")
    }

    @Test func aChoiceByTheUserIsRememberedAndKept() {
        let h = StoreHarness()
        h.defaults.set("b", forKey: "lastSessionName-test")
        h.tmux.sessions = [session("a"), session("c")]
        h.start()

        h.store.selectedID = "$c"
        #expect(h.lastSessionName == "c")

        // The old favorite showing up now must not pull the selection away.
        h.tmux.sessions = [session("a"), session("b"), session("c")]
        h.refresh()
        #expect(h.store.selectedID == "$c")
    }

    @Test func selectionFallsBackWhenTheSelectedSessionDisappears() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        h.store.selectedID = "$b"

        h.tmux.sessions = [session("a")]
        h.refresh()
        #expect(h.store.selectedID == "$a")
        // The fallback isn't a choice: the remembered name stays.
        #expect(h.lastSessionName == "b")
    }

    @Test func selectionIsClearedWhenNoSessionsRemain() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        h.tmux.sessions = []
        h.refresh()
        #expect(h.store.selectedID == nil)
    }

    @Test func rememberedNameIsPerSocket() {
        let h = StoreHarness()
        h.tmux.socketName = "other"
        h.defaults.set("b", forKey: "lastSessionName-test")
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        #expect(h.store.selectedID == "$a")
    }

    @Test func recentSessionsFollowSelectionAndDropVanishedOnes() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b"), session("c")]
        h.start()
        h.store.selectedID = "$b"
        h.store.selectedID = "$c"
        #expect(h.store.recentIDs == ["$c", "$b", "$a"])

        h.tmux.sessions = [session("a"), session("c")]
        h.refresh()
        #expect(h.store.recentIDs == ["$c", "$a"])
    }
}

struct SessionStoreRestoreTests {
    private func restoring() -> StoreHarness {
        let h = StoreHarness()
        h.tmux.hasResurrectSave = true
        h.tmux.serverRunning = false
        return h
    }

    @Test func placeholderIsHiddenWhileRestoring() {
        let h = restoring()
        h.start()
        #expect(h.tmux.startedServer)
        #expect(h.store.isRestoring)
        #expect(h.store.sessions.isEmpty)
        #expect(h.store.selectedID == nil)
        #expect(!h.store.isLive) // nothing to attach a control client to
    }

    @Test func restoreEndsWhenThePlaceholderDisappears() {
        let h = restoring()
        h.defaults.set("work", forKey: "lastSessionName-test")
        h.start()

        // tmux-resurrect restores the sessions and kills the placeholder.
        h.tmux.sessions = [session("play"), session("work")]
        h.scheduler.run(for: 1) // the next poll
        #expect(!h.store.isRestoring)
        #expect(h.store.sessions.map(\.name) == ["play", "work"])
        #expect(h.store.selectedID == "$work")
    }

    @Test func restoreKeepsWaitingWhileOnlyThePlaceholderExists() {
        let h = restoring()
        h.start()
        h.scheduler.run(for: 19)
        #expect(h.store.isRestoring)
        #expect(h.store.sessions.isEmpty)
    }

    @Test func placeholderIsShownAfterTheTimeout() {
        let h = restoring()
        h.start()
        h.scheduler.run(for: 21)
        #expect(!h.store.isRestoring)
        #expect(h.store.sessions.map(\.id) == ["$0"])
        #expect(h.store.selectedID == "$0")
    }

    @Test func timeoutDoesNothingAfterTheRestoreFinished() {
        let h = restoring()
        h.start()
        h.tmux.sessions = [session("a")]
        h.scheduler.run(for: 1)
        #expect(!h.store.isRestoring)
        // A later session with the placeholder's id isn't hidden or re-restored.
        h.scheduler.run(for: 30)
        #expect(!h.store.isRestoring)
        #expect(h.store.sessions.map(\.name) == ["a"])
    }

    @Test func noRestoreWithoutASave() {
        let h = StoreHarness()
        h.tmux.serverRunning = false
        h.start()
        #expect(!h.tmux.startedServer)
        #expect(!h.store.isRestoring)
    }

    @Test func noRestoreWhileTheServerRuns() {
        let h = StoreHarness()
        h.tmux.hasResurrectSave = true
        h.tmux.sessions = [session("a")]
        h.start()
        #expect(!h.tmux.startedServer)
        #expect(!h.store.isRestoring)
        #expect(h.store.sessions.map(\.name) == ["a"])
    }
}

struct SessionStoreAlertTests {
    @Test func raiseAndClear() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()

        h.store.raiseAlert(sessionID: "$a", message: nil)
        #expect(h.store.alerts == ["$a": TerminalAlert(message: nil)])
        #expect(h.store.needsAttention(session("a")))
        #expect(!h.store.needsAttention(session("b")))

        h.store.clearAlert(sessionID: "$a")
        #expect(h.store.alerts.isEmpty)
        #expect(!h.store.needsAttention(session("a")))
        h.store.clearAlert(sessionID: "$a") // already clear: no-op
    }

    @Test func aBellAfterANotificationKeepsItsText() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        h.store.raiseAlert(sessionID: "$a", message: "Claude is waiting")
        h.store.raiseAlert(sessionID: "$a", message: nil)
        #expect(h.store.alerts["$a"]?.message == "Claude is waiting")
    }

    @Test func aNewNotificationReplacesTheText() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        h.store.raiseAlert(sessionID: "$a", message: "first")
        h.store.raiseAlert(sessionID: "$a", message: "second")
        #expect(h.store.alerts["$a"]?.message == "second")
    }

    @Test func alertsOfVanishedSessionsArePruned() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        h.store.raiseAlert(sessionID: "$a", message: nil)
        h.store.raiseAlert(sessionID: "$b", message: "hi")

        h.tmux.sessions = [session("a")]
        h.refresh()
        #expect(Set(h.store.alerts.keys) == ["$a"])
    }

    @Test func tmuxsOwnBellFlagNeedsAttention() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a", bell: true), session("b")]
        h.start()
        #expect(h.store.needsAttention(h.store.sessions[0]))
        #expect(!h.store.needsAttention(h.store.sessions[1]))
        #expect(h.store.alerts.isEmpty)
    }
}

struct SessionStoreErrorTests {
    private struct Boom: Error, CustomStringConvertible {
        var description: String
    }

    @Test func noErrorByDefault() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        #expect(h.store.errorMessage == nil)
    }

    @Test func aCommandErrorPersistsAcrossASuccessfulListing() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()

        h.store.perform { _ in throw Boom(description: "duplicate session: a") }
        h.scheduler.run() // the command fails, then the list is refreshed
        #expect(h.store.errorMessage == "duplicate session: a")

        h.refresh()
        h.scheduler.run(for: 3) // and polls or control events
        #expect(h.store.errorMessage == "duplicate session: a")
    }

    @Test func aCommandErrorClearsWhenTheNextCommandSucceeds() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        h.store.perform { _ in throw Boom(description: "nope") }
        h.scheduler.run()
        #expect(h.store.errorMessage == "nope")

        h.store.perform { tmux in try tmux.killSession(id: "$zzz") }
        h.scheduler.run()
        #expect(h.tmux.calls == ["kill-session $zzz"])
        #expect(h.store.errorMessage == nil)
    }

    @Test func aCommandErrorCanBeDismissed() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        h.store.perform { _ in throw Boom(description: "nope") }
        h.scheduler.run()
        h.store.dismissCommandError()
        #expect(h.store.errorMessage == nil)
    }

    @Test func aListingErrorClearsOnTheNextSuccessfulListing() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.tmux.listError = TmuxError(description: "tmux: no server")
        h.start()
        #expect(h.store.errorMessage == "tmux: no server")
        #expect(h.store.sessions.isEmpty)

        h.tmux.listError = nil
        h.scheduler.run(for: 1)
        #expect(h.store.errorMessage == nil)
        #expect(h.store.sessions.map(\.name) == ["a"])
    }

    @Test func aFailedListingKeepsTheLastSessions() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        h.tmux.listError = TmuxError(description: "flaky")
        h.store.perform { _ in } // forces a refresh over the control connection
        h.scheduler.run()
        #expect(h.store.errorMessage == "flaky")
        #expect(h.store.sessions.map(\.name) == ["a"])
    }

    @Test func aConnectionErrorStaysUntilTheClientConnects() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.controlFailure = Boom(description: "spawn failed")
        h.start()
        #expect(h.store.errorMessage == "tmux control mode: spawn failed")
        #expect(!h.store.isLive)

        // Listing succeeds meanwhile; the error is about the connection.
        h.scheduler.run(for: 2)
        #expect(h.store.errorMessage == "tmux control mode: spawn failed")

        h.controlFailure = nil
        h.scheduler.run(for: 1)
        #expect(h.store.isLive)
        #expect(h.store.errorMessage == nil)
    }

    @Test func errorSourcesAreShownInOrderOfPriority() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.controlFailure = Boom(description: "spawn failed")
        h.tmux.listError = TmuxError(description: "list failed")
        h.start()
        // Listing failed, so there was no session to attach to.
        #expect(h.store.errorMessage == "list failed")

        h.tmux.listError = nil
        h.scheduler.run(for: 1)
        #expect(h.store.errorMessage == "tmux control mode: spawn failed")

        h.store.perform { _ in throw Boom(description: "command failed") }
        h.scheduler.run()
        #expect(h.store.errorMessage == "command failed")
    }

    @Test func aReplyFailingBecauseTheConnectionDroppedIsNotShown() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        let control = h.control!
        control.holdReplies = true
        h.store.refresh()

        // The client reports its exit before failing its pending replies.
        control.exit()
        h.scheduler.run()
        control.answerHeld(.failure(TmuxError(description: "tmux control client has exited")))
        h.scheduler.run()
        #expect(h.store.errorMessage == nil)
    }
}

struct SessionStoreConnectionTests {
    @Test func pollsUntilThereIsASessionThenSwitchesToControlMode() {
        let h = StoreHarness()
        h.start()
        #expect(!h.store.isLive)
        #expect(h.controls.isEmpty)
        #expect(h.scheduler.activeTimers == 1)

        h.scheduler.run(for: 3)
        #expect(h.tmux.listCount >= 3)
        #expect(h.controls.isEmpty)

        h.tmux.sessions = [session("b"), session("a")]
        h.scheduler.run(for: 1)
        #expect(h.store.isLive)
        #expect(h.controls.count == 1)
        // It attaches to the first session in the list order.
        #expect(h.control?.sessionID == h.store.sessions.first?.id)
        #expect(h.scheduler.activeTimers == 0)
    }

    @Test func listsOverTheControlConnectionOnceLive() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        let cliLists = h.tmux.listCount
        let controlLists = h.control!.listCount
        #expect(controlLists >= 1) // catches up on what changed while attaching

        h.scheduler.run(for: 5) // no polling any more
        #expect(h.tmux.listCount == cliLists)
        #expect(h.control!.listCount == controlLists)

        h.tmux.sessions = [session("a"), session("b")]
        h.refresh()
        #expect(h.tmux.listCount == cliLists)
        #expect(h.store.sessions.map(\.name) == ["a", "b"])
    }

    @Test func notificationsRefreshAndBurstsAreCoalesced() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        let before = h.control!.listCount

        h.tmux.sessions = [session("a")]
        h.control!.notify("%sessions-changed")
        h.control!.notify("%window-close", ["@1"])
        h.control!.notify("%unlinked-window-close", ["@2"])
        h.scheduler.run(for: 0.01)
        #expect(h.control!.listCount == before) // not yet: 50 ms

        h.scheduler.run(for: 0.1)
        #expect(h.control!.listCount == before + 1)
        #expect(h.store.sessions.map(\.name) == ["a"])
    }

    @Test func otherNotificationsDoNotRefresh() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        let before = h.control!.listCount
        h.control!.notify("%output", ["%1", "x"])
        h.control!.notify("%pause", ["%1"])
        h.scheduler.run(for: 1)
        #expect(h.control!.listCount == before)
    }

    @Test func fallsBackToPollingWhenTheConnectionEnds() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        #expect(h.store.isLive)
        let cliLists = h.tmux.listCount

        h.control!.exit()
        h.scheduler.run()
        #expect(h.tmux.listCount > cliLists) // refreshed over the CLI at once

        // ...and reconnects once polling finds a session to attach to.
        h.scheduler.run(for: 1)
        #expect(h.controls.count == 2)
        #expect(h.store.isLive)
        #expect(h.scheduler.activeTimers == 0)
    }

    @Test func staysOnPollingWhileTheServerHasNoSessionAfterTheConnectionEnds() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()

        h.tmux.sessions = []
        h.control!.exit()
        h.scheduler.run(for: 3)
        #expect(!h.store.isLive)
        #expect(h.controls.count == 1)
        #expect(h.scheduler.activeTimers == 1)
        #expect(h.store.sessions.isEmpty)

        h.tmux.sessions = [session("z")]
        h.scheduler.run(for: 1)
        #expect(h.store.isLive)
        #expect(h.controls.count == 2)
        #expect(h.control?.sessionID == "$z")
    }

    @Test func anOldConnectionsExitIsIgnored() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        let first = h.control!
        first.exit()
        h.scheduler.run(for: 1)
        #expect(h.controls.count == 2)

        first.exit() // e.g. the stall detector firing late
        h.scheduler.run(for: 1)
        #expect(h.store.isLive)
        #expect(h.controls.count == 2)
    }

    @Test func sessionRenamesFollowTheEventImmediately() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()

        // The event updates the name before the refresh answers.
        h.tmux.sessions = [session("a"), TmuxSession(id: "$b", name: "bee", windows: [], attachedClients: 0)]
        h.control!.notify("%session-renamed", ["$b", "bee"])
        #expect(h.store.sessions.map(\.name) == ["a", "bee"])
        h.scheduler.run(for: 0.1)
        #expect(h.store.sessions.map(\.name) == ["a", "bee"])
        // The sidebar keeps the row's place under the new name.
        #expect(h.store.layout.entries.contains(.session("bee")))
        #expect(!h.store.layout.entries.contains(.session("b")))
    }

    @Test func clientSessionChangeIsForwarded() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        var seen: [String] = []
        h.store.onClientSessionChanged = { seen.append($0 + " " + $1) }
        h.control!.notify("%client-session-changed", ["/dev/ttys004", "$a"])
        #expect(seen == ["/dev/ttys004 $a"])
    }

    @Test func performRefreshesThenCompletes() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a")]
        h.start()
        var done = false
        h.store.selectWindow("@a", in: "$a")
        h.store.perform({ _ in }, then: { done = true })
        h.scheduler.run()
        #expect(h.tmux.calls == ["select-window $a @a"])
        #expect(done)
    }
}

struct SessionStoreLayoutTests {
    @Test func layoutIsStoredInTheInjectedDefaultsPerSocket() throws {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        let data = try #require(h.defaults.data(forKey: "sidebarLayout-test"))
        let saved = try JSONDecoder().decode(SidebarLayout.self, from: data)
        #expect(saved == h.store.layout)
        #expect(saved.entries == [.session("a"), .session("b")])
    }

    @Test func aSavedLayoutOrdersTheSessions() throws {
        let h = StoreHarness()
        var layout = SidebarLayout()
        layout.include(["b", "a"])
        h.defaults.set(try JSONEncoder().encode(layout), forKey: "sidebarLayout-test")
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        #expect(h.store.sessions.map(\.name) == ["b", "a"])
    }

    @Test func groupsFileSessionsAndSurviveInTheStore() {
        let h = StoreHarness()
        h.tmux.sessions = [session("a"), session("b")]
        h.start()
        #expect(h.store.addGroup("Work", moving: "$b"))
        #expect(!h.store.addGroup("Work"))
        #expect(h.store.sessions.map(\.name) == ["a", "b"])
        #expect(h.store.sidebarRows.count == 3)
    }
}
