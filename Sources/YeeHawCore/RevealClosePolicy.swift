import Foundation

/// What ended, or may have ended, a revealed app's menu or popover. Each is only a hint:
/// `RevealClosePolicy` decides whether the reveal really ends, because switching the app off
/// under a panel that's still up leaves the panel stranded and the app's toggle out of step.
public enum RevealCloseSignal: String, CaseIterable, Sendable {
    case menuClosed = "AXMenuClosed"
    case focusMovedAway = "AXFocusedWindowChanged"
    case windowDestroyed = "AXUIElementDestroyed"
    case appDeactivated = "AXApplicationDeactivated"
    case windowsGone = "the app's menu or popover went off screen"
    case outsideClick = "mouse-down outside the app"
    case inactivity = "no activity"
}

/// What the screen and the mouse look like as a close signal is judged.
public struct RevealCloseInputs: Equatable, Sendable {
    /// A window of the app's that appeared after the press is on screen.
    public var postPressWindowsOnScreen: Bool
    /// One of those windows hangs from the menu bar: a menu, popover or panel under the icon.
    public var hangsFromBar: Bool
    /// A mouse button is held down: a click is under way somewhere.
    public var mouseButtonDown: Bool
    /// An outside click landed in the menu bar and no other app's menu or panel has finished
    /// opening from it yet.
    public var otherAppOpening: Bool
    /// Seconds since the close signal arrived.
    public var elapsed: Double

    public init(postPressWindowsOnScreen: Bool = false, hangsFromBar: Bool = false,
                mouseButtonDown: Bool = false, otherAppOpening: Bool = false, elapsed: Double = 0) {
        self.postPressWindowsOnScreen = postPressWindowsOnScreen
        self.hangsFromBar = hangsFromBar
        self.mouseButtonDown = mouseButtonDown
        self.otherAppOpening = otherAppOpening
        self.elapsed = elapsed
    }
}

public enum RevealCloseDecision: Equatable, Sendable {
    /// Not a close: the reveal goes on.
    case keepWaiting
    /// The app is done with its menu: photograph (unless skipped) and switch it off.
    case endNow
    /// A close, held back: ask again after `RevealClosePolicy.recheckInterval`; it ends within
    /// `remaining` seconds at the latest.
    case endAfterCappedWait(remaining: Double)
}

/// The decisions a reveal makes as its menu or popover may be closing, free of AppKit so they
/// can be tested (spec "Clicking an icon", step 6).
public enum RevealClosePolicy {
    /// How long a window the press opened (not one hanging from the bar) may hold the switch-off.
    public static let windowCap: Double = 3
    /// How long a held mouse button, or another app opening its menu, may hold the switch-off.
    public static let clickCap: Double = 2
    /// How often a held close is judged again.
    public static let recheckInterval: Double = 0.1

    public static func decide(_ signal: RevealCloseSignal, _ inputs: RevealCloseInputs) -> RevealCloseDecision {
        // Switching off under a hanging menu or popover strands it on a neighbour's icon.
        if inputs.hangsFromBar { return .keepWaiting }
        var remaining = 0.0
        if inputs.postPressWindowsOnScreen { remaining = max(remaining, windowCap - inputs.elapsed) }
        if inputs.mouseButtonDown { remaining = max(remaining, clickCap - inputs.elapsed) }
        if signal == .outsideClick, inputs.otherAppOpening { remaining = max(remaining, clickCap - inputs.elapsed) }
        return remaining > 0 ? .endAfterCappedWait(remaining: remaining) : .endNow
    }

    /// An outside click is someone moving on to another menu; a photo burst then would re-lay
    /// out the bar (the screen-recording indicator) while that menu opens.
    public static func skipsPhoto(_ signal: RevealCloseSignal) -> Bool { signal == .outsideClick }
}
