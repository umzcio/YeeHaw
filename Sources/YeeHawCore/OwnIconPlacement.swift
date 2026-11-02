/// Where YeeHaw's own icon sits relative to Control Center.
public enum OwnIconPlacement {
    public static let controlCenterIdentifier = "com.apple.menuextra.controlcenter"

    /// True when one of `ownID`'s drawn items is immediately left of Control Center (by position;
    /// each display's copy of the bar counts on its own).
    public static func isNextToControlCenter(_ items: [MenuBarItem], ownID: BundleID) -> Bool {
        let sorted = items.sorted { $0.x < $1.x }
        return zip(sorted, sorted.dropFirst()).contains { left, right in
            left.bundleID == ownID && right.appleIdentifier == controlCenterIdentifier
        }
    }
}
