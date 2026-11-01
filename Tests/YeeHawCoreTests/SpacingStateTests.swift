import Foundation
import Testing
@testable import YeeHawCore

/// What's stored, what Apply must write, which apps are up to date, and which have windows open.
@Suite struct SpacingStateTests {
    // MARK: Stored preferences

    @Test func unsetEverywhereIsStockSixteen() {
        let stored = StoredSpacing()
        #expect(stored.value == 16)
        #expect(stored.isCanonical(for: 16))
        #expect(stored.writes(for: 16).isEmpty)
    }

    @Test func currentHostSpacingWins() {
        let stored = StoredSpacing(spacing: 8, padding: 8, anySpacing: 4, anyPadding: 4)
        #expect(stored.value == 8)
        #expect(stored.isCanonical(for: 8))
    }

    @Test func anyHostSpacingIsUsedWhenTheCurrentHostIsUnset() {
        let stored = StoredSpacing(anySpacing: 6, anyPadding: 6)
        #expect(stored.value == 6)
    }

    @Test func paddingAloneIsNotStock() {
        // Something else set only the padding: the section reads 16, but Default must still
        // delete the stray key.
        let stored = StoredSpacing(padding: 4)
        #expect(stored.value == 16)
        #expect(!stored.isCanonical(for: 16))
        #expect(stored.writes(for: 16) == [.init(host: .current, key: SpacingPlan.selectionPaddingKey, value: nil)])
    }

    @Test func mismatchedKeysAreNotCanonical() {
        let stored = StoredSpacing(spacing: 8, padding: 16)
        #expect(stored.value == 8)
        #expect(stored.writes(for: 8) == [.init(host: .current, key: SpacingPlan.selectionPaddingKey, value: 8)])
    }

    @Test func newValueWritesBothCurrentHostKeysOnly() {
        let stored = StoredSpacing(anySpacing: 4, anyPadding: 4)
        #expect(stored.writes(for: 8) == [
            .init(host: .current, key: SpacingPlan.spacingKey, value: 8),
            .init(host: .current, key: SpacingPlan.selectionPaddingKey, value: 8),
        ])
    }

    @Test func defaultDeletesEveryStoredKeyOnBothHosts() {
        let stored = StoredSpacing(spacing: 8, padding: 8, anySpacing: 4)
        #expect(stored.writes(for: 16) == [
            .init(host: .current, key: SpacingPlan.spacingKey, value: nil),
            .init(host: .current, key: SpacingPlan.selectionPaddingKey, value: nil),
            .init(host: .any, key: SpacingPlan.spacingKey, value: nil),
        ])
    }

    @Test func sameValueNeedsNoWrite() {
        #expect(StoredSpacing(spacing: 8, padding: 8).writes(for: 8).isEmpty)
    }

    @Test func storedValuesAreReadUnclamped() {
        #expect(SpacingPlan.storedValue(nil) == nil)
        #expect(SpacingPlan.storedValue(8) == 8)
        #expect(SpacingPlan.storedValue("12") == 12)
        #expect(SpacingPlan.storedValue(40) == 40)
        // Set but unreadable: still a key to delete, never equal to a value Apply writes.
        #expect(SpacingPlan.storedValue("wide") == SpacingPlan.unreadable)
        let garbage = StoredSpacing(spacing: SpacingPlan.unreadable)
        #expect(garbage.value == 16)
        #expect(!garbage.isCanonical(for: 16))
        // Out of range: reads clamped, but writing 32 replaces it.
        let wide = StoredSpacing(spacing: 40, padding: 40)
        #expect(wide.value == 32)
        #expect(!wide.isCanonical(for: 32))
    }

    // MARK: History: which apps already have the stored value

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func noHistoryMeansEveryAppIsUpToDate() {
        #expect(SpacingHistory.spacing(atLaunch: Self.t0, history: nil) == nil)
    }

    @Test func appGetsTheValueInEffectWhenItLaunched() {
        var history = SpacingHistory(before: 16)
        history.record(8, at: Self.t0)
        history.record(4, at: Self.t0 + 100)
        #expect(history.spacing(atLaunch: Self.t0 - 1) == 16)
        #expect(history.spacing(atLaunch: Self.t0 + 1) == 8)
        #expect(history.spacing(atLaunch: Self.t0 + 100) == 4)
        #expect(history.spacing(atLaunch: Self.t0 + 500) == 4)
        // No launch date known: assume the worst, the value before any change.
        #expect(SpacingHistory.spacing(atLaunch: nil, history: history) == 16)
    }

    @Test func historyKeepsTheLastChangesOnly() {
        var history = SpacingHistory(before: 16)
        for index in 0..<30 { history.record(index % 32, at: Self.t0 + Double(index)) }
        #expect(history.changes.count == SpacingHistory.limit)
        #expect(history.changes.last?.value == 29)
        // What preceded the oldest change kept.
        #expect(history.spacing(atLaunch: Self.t0 - 1) == (29 - SpacingHistory.limit) % 32)
    }

    @Test func historyThatMatchesTheStoredValueIsKept() {
        var history = SpacingHistory(before: 16)
        history.record(8, at: Self.t0)
        #expect(history.latest == 8)
        #expect(SpacingHistory.reconciled(history, stored: 8, at: Self.t0 + 60) == history)
        #expect(SpacingHistory.reconciled(nil, stored: 8, at: Self.t0 + 60) == nil)
    }

    @Test func aChangeMadeOutsideYeeHawStartsAFreshHistory() {
        // YeeHaw stored 8 at t0; then `defaults delete` put the Mac back at 16, noticed at t0 + 60.
        var history = SpacingHistory(before: 16)
        history.record(8, at: Self.t0)
        let fresh = SpacingHistory.reconciled(history, stored: 16, at: Self.t0 + 60)
        #expect(fresh?.latest == 16)
        #expect(fresh?.changes.isEmpty == true)
        #expect(fresh?.since == Self.t0 + 60)
        // When the outside change happened is unknown, so apps that launched before it was
        // noticed draw an unknown spacing; apps launched after have the stored one.
        #expect(SpacingHistory.spacing(atLaunch: Self.t0 + 30, history: fresh) == nil)
        #expect(SpacingHistory.spacing(atLaunch: Self.t0 - 30, history: fresh) == nil)
        #expect(SpacingHistory.spacing(atLaunch: nil, history: fresh) == nil)
        #expect(SpacingHistory.spacing(atLaunch: Self.t0 + 90, history: fresh) == 16)
        // A later change YeeHaw makes is tracked from there.
        var later = fresh!
        later.record(4, at: Self.t0 + 120)
        #expect(SpacingHistory.spacing(atLaunch: Self.t0 + 90, history: later) == 16)
        #expect(SpacingHistory.spacing(atLaunch: Self.t0 + 150, history: later) == 4)
        #expect(SpacingHistory.spacing(atLaunch: Self.t0 + 30, history: later) == nil)
    }

    @Test func historyWithoutAStartDecodesFromTheOldFormat() throws {
        let old = Data(#"{"before":16,"changes":[{"date":0,"value":8}]}"#.utf8)
        let history = try JSONDecoder().decode(SpacingHistory.self, from: old)
        #expect(history.since == nil)
        #expect(history.latest == 8)
    }

    @Test func historyRoundTrips() throws {
        var history = SpacingHistory(before: 16)
        history.record(8, at: Self.t0)
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(SpacingHistory.self, from: data) == history)
    }

    // MARK: Which apps have windows open

    static func facts(hidden: Bool = false, regular: Bool = true, ax: Int? = 0, onScreen: Int = 0,
                      anywhere: Int = 0, pid: Int32 = 42) -> WindowFacts {
        WindowFacts(pid: pid, isHidden: hidden, isRegular: regular, axWindows: ax,
                    onScreenWindows: onScreen, windowsAnywhere: anywhere)
    }

    @Test func noWindowsAnywhereIsWindowless() {
        #expect(!SpacingPlan.hasOpenWindows(Self.facts()))
    }

    @Test func accessibilityWindowsCountEvenWhenHidden() {
        // Outlook hidden with Command-H with a draft open: its windows are still open.
        #expect(SpacingPlan.hasOpenWindows(Self.facts(hidden: true, ax: 1, anywhere: 1)))
    }

    @Test func appYeeHawHidDuringItsRestartIsWindowlessWhileStillHidden() {
        let exempt: Set<Int32> = [42]
        #expect(!SpacingPlan.hasOpenWindows(Self.facts(hidden: true, ax: 1, anywhere: 1), exempt: exempt))
        // Once the user shows it, its windows count again.
        #expect(SpacingPlan.hasOpenWindows(Self.facts(hidden: false, ax: 1, onScreen: 1), exempt: exempt))
        // A different process of the same app isn't exempt.
        #expect(SpacingPlan.hasOpenWindows(Self.facts(hidden: true, ax: 1, pid: 7), exempt: exempt))
    }

    @Test func regularAppWithAWindowInAnotherSpaceHasWindows() {
        // Accessibility lists only the current Space's windows; a full-screen window elsewhere
        // still shows up in the window server's full list.
        #expect(SpacingPlan.hasOpenWindows(Self.facts(ax: 0, anywhere: 1)))
    }

    @Test func accessoryAppsOffScreenWindowsDontCount() {
        // Menu bar apps keep closed windows around off screen (Tailscale has five).
        #expect(!SpacingPlan.hasOpenWindows(Self.facts(regular: false, ax: 0, anywhere: 5)))
    }

    @Test func onScreenWindowCountsWhenAccessibilityCantBeRead() {
        #expect(SpacingPlan.hasOpenWindows(Self.facts(regular: false, ax: nil, onScreen: 1, anywhere: 1)))
        #expect(!SpacingPlan.hasOpenWindows(Self.facts(regular: false, ax: nil, anywhere: 3)))
    }

    // MARK: Order

    @Test func drawnAppsInBarOrderThenHiddenOnes() {
        #expect(SpacingPlan.appOrder(drawn: ["b", nil, "a", "b"], hidden: ["c", "a"]) == ["b", "a", "c"])
    }
}
