import Foundation
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

    @Test func launchDropsUntrackedFromHiddenButKeepsThemJournaled() {
        let s = Self.state(hidden: ["A", "G"], journal: ["A", "G", "H"])
        let r = Reconciler.onLaunch(s, allow: ["A": false])
        #expect(r.actions.isEmpty)
        #expect(r.state.hidden == ["A"])
        #expect(r.state.journal == ["A", "G", "H"])
    }

    @Test func quitAndLaunchTogetherNeverLoseAnAppWithNoEntry() {
        let r = Reconciler.onLaunch(Self.state(journal: ["Z"]), allow: [:])
        #expect(r.actions.isEmpty)
        #expect(r.state.journal == ["Z"])
        let again = Reconciler.onLaunch(r.state, allow: ["Z": false])
        #expect(again.actions == [.switchOn("Z")])
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

    // MARK: Running copies' locations

    static let debugA = AllowLocation.adhocBinary("file:///dev/A.app/Contents/MacOS/A")

    @Test func hideListsTheRunningCopiesBeforeSwitchingOff() {
        let r = Reconciler.hide("A", Self.state(), allow: ["A": true], locations: [.bundle("A"), Self.debugA])
        #expect(r.actions == [.addLocation("A", .bundle("A")), .addLocation("A", Self.debugA), .switchOff("A")])
    }

    @Test func showListsTheRunningCopyBeforeSwitchingOn() {
        let r = Reconciler.show("A", Self.state(hidden: ["A"], journal: ["A"]), locations: [.bundle("A")])
        #expect(r.actions == [.addLocation("A", .bundle("A")), .switchOn("A")])
        // Nothing to switch, nothing to list.
        #expect(Reconciler.show("B", Self.state(hidden: ["B"]), locations: [.bundle("B")]).actions.isEmpty)
    }

    @Test func launchListsTheRunningCopiesOfHiddenApps() {
        let s = Self.state(hidden: ["A", "B"], journal: ["A", "C"])
        let r = Reconciler.onLaunch(s, allow: ["A": false, "B": true, "C": false],
                                    locations: ["A": [.bundle("A")], "B": [Self.debugA], "C": [.bundle("C")]])
        // C is switched back on, not hidden: its copy needn't be listed.
        #expect(r.actions == [.addLocation("A", .bundle("A")), .addLocation("B", Self.debugA),
                              .switchOff("B"), .switchOn("C")])
    }

    @Test func aHiddenAppOpenedFromAnotherCopyIsListedAndSwitchedOffAgain() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        #expect(Reconciler.launched("A", s, allow: ["A": false], locations: [Self.debugA])
            == [.addLocation("A", Self.debugA), .switchOff("A")])
    }

    @Test func anAppOpenedThatIsntHiddenIsLeftAlone() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        #expect(Reconciler.launched("B", s, allow: ["B": true], locations: [.bundle("B")]).isEmpty)
        // Untracked, or no copy to list: nothing to write.
        #expect(Reconciler.launched("A", s, allow: [:], locations: [.bundle("A")]).isEmpty)
        #expect(Reconciler.launched("A", s, allow: ["A": false], locations: []).isEmpty)
        // Quitting switched it back on and cleared the journal: it stays on.
        #expect(Reconciler.launched("A", Self.state(hidden: ["A"]), allow: ["A": true], locations: [Self.debugA]).isEmpty)
    }

    @Test func aHiddenAppBeingRevealedIsLeftToTheReveal() {
        let s = Self.state(hidden: ["A"], journal: ["A"], pending: PendingReveal(bundleID: "A", originalPositions: [:]))
        #expect(Reconciler.launched("A", s, allow: ["A": true], locations: [Self.debugA]).isEmpty)
    }

    @Test func userSwitchingOnWins() {
        let s = Self.state(hidden: ["A"], journal: ["A"])
        let n = Reconciler.externalChange(s, before: ["A": false], after: ["A": true])
        #expect(n.hidden.isEmpty)
        #expect(n.journal.isEmpty)
    }

    @Test func userSwitchingOffAnAppYeeHawHasntHiddenYetMakesItTheirs() {
        let s = Self.state(hidden: ["A", "B"], journal: ["B"])
        let n = Reconciler.externalChange(s, before: ["A": true, "B": false], after: ["A": false, "B": false])
        #expect(n.hidden == ["B"])
        #expect(n.journal == ["B"])
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

    @Test func launchDropsAHiddenAppTheUserSwitchedOff() {
        // Quit switched A back on and cleared the journal; the user then switched A off in System
        // Settings while YeeHaw wasn't running. Apple's switch wins: A is the user's now.
        let s = Self.state(hidden: ["A"])
        let r = Reconciler.onLaunch(s, allow: ["A": false])
        #expect(r.actions.isEmpty)
        #expect(r.state.hidden.isEmpty)
        #expect(r.state.journal.isEmpty)
    }

    @Test func launchKeepsAHiddenAppItStillHasSwitchedOff() {
        let s = Self.state(hidden: ["A", "B"], journal: ["A"])
        let r = Reconciler.onLaunch(s, allow: ["A": false, "B": true])
        #expect(r.actions == [.switchOff("B")])
        #expect(r.state.hidden == ["A", "B"])
        #expect(r.state.journal == ["A", "B"])
    }

    @Test func quitRestoresAPendingReveal() {
        let p = PendingReveal(bundleID: "A", originalPositions: ["status:A::Item-0": 375.5])
        let s = Self.state(hidden: ["A"], journal: ["A"], pending: p)
        let r = Reconciler.onQuit(s)
        #expect(r.actions == [.switchOn("A")])
        #expect(r.restorePositions == ["status:A::Item-0": 375.5])
        #expect(r.state.pendingReveal == nil)
        #expect(r.state.journal.isEmpty)
    }

    @Test func savedStateMissingNewerFieldsStillDecodes() throws {
        // A state saved before `needsGrant` existed, with an unknown extra field.
        let json = #"{"hidden":["A"],"journal":["A"],"somethingNew":1}"#
        let state = try JSONDecoder().decode(HidingState.self, from: Data(json.utf8))
        #expect(state == HidingState(hidden: ["A"], journal: ["A"]))
    }

    @Test func savedStateRoundTrips() throws {
        let p = PendingReveal(bundleID: "A", originalPositions: ["k": 1, "gone": nil])
        let state = HidingState(hidden: ["A", "B"], journal: ["A"], pendingReveal: p, needsGrant: [.positions])
        #expect(try JSONDecoder().decode(HidingState.self, from: JSONEncoder().encode(state)) == state)
    }
}
