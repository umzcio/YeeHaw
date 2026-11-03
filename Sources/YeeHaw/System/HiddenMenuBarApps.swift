import AppKit
import os
import YeeHawCore

/// Shows menu bar apps that may be hidden because of YeeHaw. Earlier versions of Spacing Apply
/// reopened the apps they restarted hidden and never showed them again; such an app still gets its
/// menu bar item's clicks but can't open the panel or popover they show. Unhiding also brings back
/// any window the app opened while hidden, which is the app's own.
@MainActor
enum HiddenMenuBarApps {
    private static let log = Logger(subsystem: Log.subsystem, category: "spacing")
    /// Set once the launch pass has run, so an app someone hides on purpose later stays hidden.
    static let unhidOnceKey = "UnhidAppsLeftHiddenBySpacing"

    /// Unhides every running app `SpacingPlan.shouldUnhide` picks, without activating it.
    /// `menuBarOwners` are the apps known to own a menu bar item. Returns the names of the apps
    /// it unhid.
    @discardableResult
    static func unhideAll(menuBarOwners: Set<BundleID>, own: BundleID = OwnIconLocator.bundleID) -> [String] {
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.isHidden && !app.isTerminated {
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { continue }
            let facts = RunningAppFacts(bundleID: id, bundlePath: url.path, isHidden: true,
                                        isRegular: app.activationPolicy == .regular)
            guard SpacingPlan.shouldUnhide(facts, menuBarOwners: menuBarOwners, own: own) else { continue }
            if app.unhide() {
                names.append(app.localizedName ?? id)
            } else {
                log.error("Couldn't unhide \(id, privacy: .public)")
            }
        }
        if !names.isEmpty {
            log.notice("Unhid \(names.joined(separator: ", "), privacy: .public)")
        }
        return names
    }

    /// The launch pass, run once per Mac user: apps an earlier Spacing Apply left hidden are shown,
    /// so nobody has to find and restart them by hand.
    static func unhideOnce(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: unhidOnceKey) else { return }
        let owners = Set(await AXMenuBarReader().items().compactMap(\.bundleID))
        unhideAll(menuBarOwners: owners)
        defaults.set(true, forKey: unhidOnceKey)
    }
}
