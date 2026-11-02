import AppKit
import Observation
import SwiftUI
import YeeHawCore

/// One app in the restart list, and whether it's ticked.
struct SpacingCandidate: Identifiable, Equatable {
    let app: RunningMenuBarApp
    var ticked: Bool
    /// The spacing it picked up at launch, when YeeHaw knows it (see `SpacingHistory`).
    var spacingAtLaunch: Int?
    var id: BundleID { app.bundleID }
}

/// What the last Apply did, shown under the section until dismissed or the slider moves.
struct SpacingReport: Equatable {
    let value: Int
    let result: SpacingApplier.Result

    var saved: Bool { result.saved }
    var wrote: Bool { result.wrote }
    var restarted: [SpacingApplier.Restart] { result.restarted }
    var skipped: [SpacingApplier.Skip] { result.skipped }

    /// Something didn't go as asked: the banner shows a warning rather than a check.
    var isWarning: Bool {
        !saved || !skipped.isEmpty || restarted.contains { !$0.iconReturned }
    }

    var headline: String {
        if !saved { return "Couldn’t save the spacing." }
        if value == SpacingPlan.defaultValue {
            return wrote ? "Spacing set back to the macOS default, \(value) pt." : "Spacing is the macOS default, \(value) pt."
        }
        return wrote ? "Spacing set to \(value) pt." : "Spacing is \(value) pt."
    }

    /// A line for what was restarted, one per app whose icon is still missing, then one per
    /// skipped app.
    var detail: [String] {
        guard saved else { return ["Nothing was changed, and no apps were restarted."] }
        var lines: [String] = []
        let back = restarted.filter(\.iconReturned).map(\.app.name)
        if restarted.isEmpty, skipped.isEmpty {
            lines.append("No apps were restarted. Apps use the new spacing the next time they open.")
        }
        if !back.isEmpty {
            lines.append("Restarted \(back.formatted(.list(type: .and))).")
        }
        for restart in restarted where !restart.iconReturned {
            lines.append("\(restart.app.name) restarted, but its icon hasn’t come back yet.")
        }
        for skip in skipped {
            let name = skip.app.name
            switch skip.reason {
            case .refusedToQuit:
                lines.append("\(name) didn’t quit, so it keeps the old spacing until it next opens.")
            case .stillQuitting:
                lines.append("\(name) hadn’t quit after 10 seconds. If it quits later, open it again to use the new spacing.")
            case .notRunning:
                lines.append("\(name) wasn’t running any more; it uses the new spacing when it opens.")
            case .didNotReopen:
                lines.append("\(name) quit but didn’t reopen. Open it again from Applications.")
            case .openedWindows:
                lines.append("\(name) has a window open now, so it wasn’t restarted.")
            }
        }
        return lines
    }
}

/// Item widths for the live preview.
enum SpacingPreview {
    /// A bar item's width at `spacing`: its glyph plus the spacing, half on either side. On 27.2
    /// an app's item narrows by exactly the spacing taken away (DigUp: 36 pt at 16, 28 pt at 8).
    static func itemWidth(glyph: CGFloat, spacing: Int) -> CGFloat {
        glyph + CGFloat(spacing)
    }
}

/// The layout window's spacing section: the slider's value, the apps Apply would restart and
/// what the last Apply did. Nothing is written until Apply.
@MainActor @Observable
final class SpacingModel {
    /// The slider's value.
    var value: Int {
        didSet {
            guard value != oldValue else { return }
            retick()
            // The report described another value; it would contradict the readout.
            if report != nil, value != current {
                withAnimation(LayoutModel.rowAnimation) { report = nil }
            }
        }
    }
    /// The stored value: what apps launched from now on get.
    private(set) var current: Int
    /// The stored keys don't say exactly `current` (one is missing, they differ, or an any-host
    /// key lingers at the default), so Apply has something to write even at that value.
    private(set) var needsCleanup = false
    private(set) var candidates: [SpacingCandidate] = []
    /// While Apply runs: the app being restarted, its position and how many there are.
    private(set) var progress: (name: String, index: Int, count: Int)?
    var report: SpacingReport?

    @ObservationIgnored let applier: SpacingApplier
    /// Told when an Apply has finished.
    @ObservationIgnored var onApplied: (() -> Void)?
    /// Told when an Apply starts and ends (layout edits wait for it).
    @ObservationIgnored var onApplyingChange: ((Bool) -> Void)?
    /// Ticks the user set, kept across re-reads of the running apps.
    @ObservationIgnored private var userTicks: [BundleID: Bool] = [:]

    init(applier: SpacingApplier) {
        self.applier = applier
        let stored = applier.storedState()
        current = stored.value
        value = stored.value
        needsCleanup = !stored.isCanonical(for: stored.value)
        _ = applier.reconcileHistory()
    }

    var isApplying: Bool { progress != nil }
    /// Whether Apply stores something: a new value, or tidy keys for the current one. Otherwise it
    /// only restarts apps still drawing an older spacing.
    var isWriting: Bool { value != current || needsCleanup }
    var canApply: Bool { !isApplying && (isWriting || tickedCount > 0) }
    var tickedCount: Int { candidates.count { $0.ticked } }
    var title: String { Self.applyTitle(restarting: tickedCount, writing: isWriting) }

    static func applyTitle(restarting count: Int, writing: Bool) -> String {
        switch (count, writing) {
        case (0, _): "Apply"
        case (1, true): "Apply and Restart 1 App"
        case (_, true): "Apply and Restart \(count) Apps"
        case (1, false): "Restart 1 App"
        case (_, false): "Restart \(count) Apps"
        }
    }

    /// The spacing a running app draws: what it picked up at launch, or the stored value when
    /// YeeHaw doesn't know.
    func spacing(of candidate: SpacingCandidate) -> Int {
        candidate.spacingAtLaunch ?? current
    }

    /// The secondary note on a row: restarting interrupts open windows, the app still draws an
    /// older spacing, or it already has the one chosen.
    func note(for candidate: SpacingCandidate) -> String? {
        if candidate.app.hasOpenWindows { return "Has windows open" }
        guard let launched = candidate.spacingAtLaunch else { return nil }
        if launched != value, !isWriting { return "Still at \(launched) pt" }
        if launched == value, isWriting { return "Already at \(launched) pt" }
        return nil
    }

    /// Takes a fresh list of running apps that own an item. Ignored while Apply runs: apps quit
    /// and reopen then, and the list stays as it was when Apply began.
    func setApps(_ apps: [RunningMenuBarApp]) {
        guard !isApplying else { return }
        let history = applier.reconcileHistory()
        candidates = SpacingPlan.candidates(apps, own: OwnIconLocator.bundleID).map { candidate in
            SpacingCandidate(app: candidate.app, ticked: false,
                             spacingAtLaunch: SpacingHistory.spacing(atLaunch: candidate.app.launchDate, history: history))
        }
        retick()
    }

    func setTicked(_ ticked: Bool, for id: BundleID) {
        guard !isApplying, let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        userTicks[id] = ticked
        candidates[index].ticked = ticked
    }

    /// Re-reads the stored value (another app may have changed it), keeping the slider where the
    /// user put it unless it still sat at the old value. After an outside change, what each
    /// listed app picked up at launch is re-derived from the restarted history.
    func reloadCurrent() {
        guard !isApplying else { return }
        let stored = applier.storedState()
        let history = applier.reconcileHistory()
        for index in candidates.indices {
            let launched = SpacingHistory.spacing(atLaunch: candidates[index].app.launchDate, history: history)
            if candidates[index].spacingAtLaunch != launched { candidates[index].spacingAtLaunch = launched }
        }
        let followSlider = value == current
        current = stored.value
        needsCleanup = !stored.isCanonical(for: stored.value)
        if followSlider { value = stored.value }
        retick()
    }

    /// Call when the window closes: an unapplied value and the last report are let go. An Apply
    /// under way carries on.
    func windowClosed() {
        guard !isApplying else { return }
        value = current
        report = nil
    }

    /// Writes the slider's value if it's new and restarts the ticked apps one at a time.
    func apply() async {
        guard canApply else { return }
        let value = value
        let apps = candidates.filter(\.ticked).map(\.app)
        report = nil
        progress = (apps.first?.name ?? "", 0, apps.count)
        onApplyingChange?(true)
        applier.onProgress = { [weak self] app, index, count in self?.progress = (app.name, index, count) }
        let result = await applier.apply(value, relaunch: apps)
        applier.onProgress = nil
        let stored = applier.storedState()
        current = stored.value
        needsCleanup = !stored.isCanonical(for: stored.value)
        // The restarted apps have the stored spacing now; their next tick follows the defaults.
        for restart in result.restarted {
            userTicks[restart.app.bundleID] = nil
            if let index = candidates.firstIndex(where: { $0.id == restart.app.bundleID }) {
                candidates[index].spacingAtLaunch = current
            }
        }
        progress = nil
        onApplyingChange?(false)
        retick()
        let report = SpacingReport(value: value, result: result)
        withAnimation(LayoutModel.rowAnimation) { self.report = report }
        onApplied?()
        AccessibilityNotification.Announcement("\(report.headline) \(report.detail.joined(separator: " "))").post()
    }

    /// Re-derives every tick: the user's choice, else ticked when restarting gets the app a
    /// spacing it doesn't have and it has no windows to interrupt.
    private func retick() {
        for index in candidates.indices {
            let candidate = candidates[index]
            let ticked = userTicks[candidate.id] ?? (!candidate.app.hasOpenWindows && spacing(of: candidate) != value)
            if candidates[index].ticked != ticked { candidates[index].ticked = ticked }
        }
    }
}
