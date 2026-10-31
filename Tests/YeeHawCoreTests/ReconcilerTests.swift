import Testing
@testable import YeeHawCore

@Suite struct ReconcilerTests {
    static func state(
        hidden: [BundleID] = [], journal: Set<BundleID> = [], pending: PendingReveal? = nil
    ) -> HidingState {
        var s = HidingState.empty
        s.hidden = hidden
        s.journal = journal
        s.pendingReveal = pending
        return s
    }

    @Test func launchRestoresCrashLeftovers() {
        let s = Self.state(hidden: ["A"], journal: ["A", "B"])
        let r = Reconciler.onLaunch(s, allow: ["A": true, "B": false])
        #expect(r.actions == [.switchOff("A"), .switchOn("B")])
        #expect(r.state.journal == ["A"])
        #expect(r.state.hidden == ["A"])
    }

    @Test func launchRestoresPendingReveal() {
        let p = PendingReveal(bundleID: "A", originalPositions: ["status:A::Item-0": 375.5])
        let s = Self.state(hidden: ["A"], pending: p)
        let r = Reconciler.onLaunch(s, allow: ["A": true])
        #expect(r.restorePositions == ["status:A::Item-0": 375.5])
        #expect(r.actions == [.switchOff("A")])
        #expect(r.state.pendingReveal == nil)
        #expect(r.state.journal == ["A"])
    }

    @Test func launchNoChurnForStillHiddenApp() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        let r = Reconciler.onLaunch(s, allow: ["A": false])
        #expect(r.actions.isEmpty)
        #expect(r.state == s)
    }

    @Test func launchDropsUntrackedFromHiddenAndJournal() {
        let s = Self.state(hidden: ["A", "G"], journal: ["A", "G", "H"])
        let r = Reconciler.onLaunch(s, allow: ["A": false])
        #expect(r.actions.isEmpty)
        #expect(r.state.hidden == ["A"])
        #expect(r.state.journal == ["A"])
    }

    @Test func quitSwitchesOnJournalOnly() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        let r = Reconciler.onQuit(s)
        #expect(r.actions == [.switchOn("A")])
        #expect(r.state.journal.isEmpty)
        #expect(r.state.hidden == ["A"])
    }

    @Test func hideRefusesUntracked() {
        let s = Self.state()
        let r = Reconciler.hide("X", s, allow: ["Y": true])
        #expect(r.actions.isEmpty)
        #expect(r.state == s)
    }

    @Test func hideSwitchesOffAndRecords() {
        let r = Reconciler.hide("A", Self.state(), allow: ["A": true])
        #expect(r.actions == [.switchOff("A")])
        #expect(r.state.hidden == ["A"])
        #expect(r.state.journal == ["A"])
    }

    @Test func hideRefusesAlreadyOff() {
        let s = Self.state()
        let r = Reconciler.hide("A", s, allow: ["A": false])
        #expect(r.actions.isEmpty)
        #expect(r.state == s)
    }

    @Test func showSwitchesOnJournaledApp() {
        let s = Self.state(hidden: ["A", "B"], journal: ["A", "B"])
        let r = Reconciler.show("A", s)
        #expect(r.actions == [.switchOn("A")])
        #expect(r.state.hidden == ["B"])
        #expect(r.state.journal == ["B"])
    }

    @Test func userSwitchingOnWins() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        let n = Reconciler.externalChange(s, before: ["A": false], after: ["A": true])
        #expect(n.hidden.isEmpty)
        #expect(n.journal.isEmpty)
    }

    @Test func userOwnedOffExcludesJournal() {
        let s = Self.state(journal: ["A"])
        let u = Reconciler.userOwnedOff(s, allow: ["U": false, "A": false, "V": true])
        #expect(u == ["U"])
    }

    @Test func adoptAddsToHiddenAndJournal() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        let n = Reconciler.adopt(["B", "A"], s)
        #expect(n.hidden == ["A", "B"])
        #expect(n.journal == ["A", "B"])
    }
}
