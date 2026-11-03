import Foundation
import Testing
@testable import YeeHawCore

@Suite struct RevealClosePolicyTests {
    static func at(_ elapsed: Double = 0, windows: Bool = false, hangs: Bool = false,
                   button: Bool = false, opening: Bool = false) -> RevealCloseInputs {
        RevealCloseInputs(postPressWindowsOnScreen: windows, hangsFromBar: hangs,
                          mouseButtonDown: button, otherAppOpening: opening, elapsed: elapsed)
    }

    // MARK: Nothing left, or something hanging from the bar

    @Test(arguments: RevealCloseSignal.allCases)
    func everySignalEndsAtOnceWhenNothingIsLeft(_ signal: RevealCloseSignal) {
        #expect(RevealClosePolicy.decide(signal, Self.at()) == .endNow)
    }

    @Test(arguments: RevealCloseSignal.allCases)
    func aWindowHangingFromTheBarKeepsTheRevealForEverySignal(_ signal: RevealCloseSignal) {
        #expect(RevealClosePolicy.decide(signal, Self.at(0, windows: true, hangs: true)) == .keepWaiting)
        #expect(RevealClosePolicy.decide(signal, Self.at(100, windows: true, hangs: true)) == .keepWaiting)
        #expect(RevealClosePolicy.decide(signal, Self.at(0, windows: true, hangs: true, button: true, opening: true))
                == .keepWaiting)
        #expect(RevealClosePolicy.decide(signal, Self.at(100, windows: true, hangs: true, button: true, opening: true))
                == .keepWaiting)
    }

    // MARK: Ordinary windows the press opened

    @Test func menuClosedWithAnOrdinaryWindowStillUpWaitsAtMostThreeSeconds() {
        #expect(RevealClosePolicy.decide(.menuClosed, Self.at(0, windows: true)) == .endAfterCappedWait(remaining: 3))
        #expect(RevealClosePolicy.decide(.menuClosed, Self.at(1, windows: true)) == .endAfterCappedWait(remaining: 2))
        #expect(RevealClosePolicy.decide(.menuClosed, Self.at(3, windows: true)) == .endNow)
        #expect(RevealClosePolicy.decide(.menuClosed, Self.at(4, windows: true)) == .endNow)
    }

    @Test func focusMovingAwayWhileAnotherPostPressWindowIsUpWaits() {
        #expect(RevealClosePolicy.decide(.focusMovedAway, Self.at(0, windows: true)) == .endAfterCappedWait(remaining: 3))
    }

    @Test func oneWindowDestroyedWhileAnotherHangsKeepsTheReveal() {
        #expect(RevealClosePolicy.decide(.windowDestroyed, Self.at(windows: true, hangs: true)) == .keepWaiting)
    }

    @Test func deactivationUnderAnOpenPopoverKeepsTheReveal() {
        #expect(RevealClosePolicy.decide(.appDeactivated, Self.at(windows: true, hangs: true)) == .keepWaiting)
    }

    @Test func inactivityUnderAHangingWindowKeepsTheReveal() {
        #expect(RevealClosePolicy.decide(.inactivity, Self.at(windows: true, hangs: true)) == .keepWaiting)
    }

    // MARK: Clicks

    @Test func anOutsideClickWaitsForTheMouseButtonToComeUp() {
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(0, button: true)) == .endAfterCappedWait(remaining: 2))
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(1.5, button: true)) == .endAfterCappedWait(remaining: 0.5))
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(2, button: true)) == .endNow)
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(0, button: false)) == .endNow)
    }

    @Test func anOutsideClickWaitsForTheOtherAppToFinishOpening() {
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(0.5, opening: true)) == .endAfterCappedWait(remaining: 1.5))
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(2, opening: true)) == .endNow)
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(0.5, opening: false)) == .endNow)
    }

    @Test func theOtherAppsOpeningCountsOnlyForAnOutsideClick() {
        #expect(RevealClosePolicy.decide(.menuClosed, Self.at(opening: true)) == .endNow)
    }

    @Test func aButtonHeldDuringAnyCloseHoldsTheSwitchOff() {
        #expect(RevealClosePolicy.decide(.menuClosed, Self.at(0, button: true)) == .endAfterCappedWait(remaining: 2))
    }

    @Test func theLongestRunningCapWins() {
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(1, windows: true, button: true))
                == .endAfterCappedWait(remaining: 2))
        #expect(RevealClosePolicy.decide(.outsideClick, Self.at(2.5, windows: true, button: true))
                == .endAfterCappedWait(remaining: 0.5))
    }

    // MARK: Photo and constants

    @Test(arguments: RevealCloseSignal.allCases)
    func onlyAnOutsideClickSkipsThePhoto(_ signal: RevealCloseSignal) {
        #expect(RevealClosePolicy.skipsPhoto(signal) == (signal == .outsideClick))
    }

    @Test func capsMatchTheSpec() {
        #expect(RevealClosePolicy.windowCap == 3)
        #expect(RevealClosePolicy.clickCap == 2)
        #expect(RevealClosePolicy.recheckInterval == 0.1)
    }
}
