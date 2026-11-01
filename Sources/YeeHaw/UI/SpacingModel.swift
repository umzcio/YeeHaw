import AppKit
import Observation
import SwiftUI
import YeeHawCore

/// One app in the restart list, and whether it's ticked.
struct SpacingCandidate: Identifiable, Equatable {
    let app: RunningMenuBarApp
    var ticked: Bool
    var id: BundleID { app.bundleID }
}

/// What the last Apply did, shown under the section until dismissed.
struct SpacingReport: Equatable {
    struct Skip: Equatable {
        let name: String
        let reason: SpacingApplier.SkipReason
    }

    let value: Int
    let restarted: [String]
    let skipped: [Skip]

    var headline: String {
        value == SpacingPlan.defaultValue
            ? "Spacing set back to the macOS default, \(value) pt."
            : "Spacing set to \(value) pt."
    }

    /// A line for what was restarted, then one per skipped app.
    var detail: [String] {
        var lines: [String] = []
        if restarted.isEmpty {
            if skipped.isEmpty { lines.append("No apps were restarted. Apps use the new spacing the next time they open.") }
        } else {
            lines.append("Restarted \(restarted.formatted(.list(type: .and))).")
        }
        for skip in skipped {
            switch skip.reason {
            case .declinedToQuit:
                lines.append("\(skip.name) didn’t quit, so it keeps the old spacing until it next opens.")
            case .notRunning:
                lines.append("\(skip.name) wasn’t running any more; it uses the new spacing when it opens.")
            case .didNotReopen:
                lines.append("\(skip.name) quit but didn’t reopen. Open it again from Applications.")
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
    var value: Int
    /// The stored value: what apps launched from now on get.
    private(set) var current: Int
    private(set) var candidates: [SpacingCandidate] = []
    /// While Apply runs: the app being restarted, its position and how many there are.
    private(set) var progress: (name: String, index: Int, count: Int)?
    var report: SpacingReport?

    @ObservationIgnored let applier: SpacingApplier
    /// Told when an Apply has finished.
    @ObservationIgnored var onApplied: (() -> Void)?
    /// Ticks the user set, kept across re-reads of the running apps.
    @ObservationIgnored private var userTicks: [BundleID: Bool] = [:]

    init(applier: SpacingApplier) {
        self.applier = applier
        let stored = applier.currentValue()
        current = stored
        value = stored
    }

    var isApplying: Bool { progress != nil }
    var canApply: Bool { !isApplying && value != current }
    var tickedCount: Int { candidates.count { $0.ticked } }

    static func applyTitle(restarting count: Int) -> String {
        switch count {
        case 0: "Apply"
        case 1: "Apply and Restart 1 App"
        default: "Apply and Restart \(count) Apps"
        }
    }

    /// Takes a fresh list of running apps that own an item. Ignored while Apply runs: apps quit
    /// and reopen then, and the list stays as it was when Apply began.
    func setApps(_ apps: [RunningMenuBarApp]) {
        guard !isApplying else { return }
        candidates = SpacingPlan.candidates(apps, own: OwnIconLocator.bundleID).map { candidate in
            SpacingCandidate(app: candidate.app, ticked: userTicks[candidate.app.bundleID] ?? candidate.tickedByDefault)
        }
    }

    func setTicked(_ ticked: Bool, for id: BundleID) {
        guard !isApplying, let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        userTicks[id] = ticked
        candidates[index].ticked = ticked
    }

    /// Re-reads the stored value (another app may have changed it), keeping the slider where the
    /// user put it unless it still sat at the old value.
    func reloadCurrent() {
        guard !isApplying else { return }
        let stored = applier.currentValue()
        if value == current { value = stored }
        current = stored
    }

    /// Call when the window closes: an unapplied value and the last report are let go. An Apply
    /// under way carries on.
    func windowClosed() {
        guard !isApplying else { return }
        value = current
        report = nil
    }

    /// Writes the slider's value and restarts the ticked apps one at a time.
    func apply() async {
        guard canApply else { return }
        let value = value
        let apps = candidates.filter(\.ticked).map(\.app)
        report = nil
        progress = (apps.first?.name ?? "", 0, apps.count)
        applier.onProgress = { [weak self] app, index, count in self?.progress = (app.name, index, count) }
        let result = await applier.apply(value, relaunch: apps)
        applier.onProgress = nil
        current = applier.currentValue()
        progress = nil
        let skipped = result.skipped.map { name in
            SpacingReport.Skip(name: name, reason: applier.skipReasons[name] ?? .declinedToQuit)
        }
        let report = SpacingReport(value: value, restarted: result.restarted, skipped: skipped)
        withAnimation(LayoutModel.rowAnimation) { self.report = report }
        onApplied?()
        AccessibilityNotification.Announcement("\(report.headline) \(report.detail.joined(separator: " "))").post()
    }
}
