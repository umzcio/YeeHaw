import AppKit
import ApplicationServices
import YeeHawCore

/// Reads what `MenuBarAgent` draws and which app owns each item (spec Technique 1).
///
/// AX calls are synchronous and can block, so the walk runs off the main actor. `AXUIElement`
/// isn't Sendable: elements never leave the nonisolated walk, only `DrawnItem`/`AppExtra` do.
struct AXMenuBarReader: MenuBarReading {
    static let agentBundleID = "com.apple.MenuBarAgent"
    /// Per-app messaging timeout, so one hung app can't stall the read.
    static let appTimeout: Float = 0.3

    func items() async -> [MenuBarItem] {
        await Self.readItems()
    }

    func runningBundleIDs() async -> Set<BundleID> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    @concurrent
    private static func readItems() async -> [MenuBarItem] {
        let apps = NSWorkspace.shared.runningApplications
        guard let agent = apps.first(where: { $0.bundleIdentifier == agentBundleID }) else { return [] }
        let owners = apps.compactMap { app -> (pid_t, BundleID)? in
            guard let id = app.bundleIdentifier, id != agentBundleID else { return nil }
            return (app.processIdentifier, id)
        }
        let drawn = drawnItems(agentPID: agent.processIdentifier)
        let extras = owners.flatMap { appExtras(pid: $0.0, bundleID: $0.1) }
        return ItemMatcher.match(drawn: drawn, extras: extras)
    }

    // MARK: What's drawn

    /// Every item in the agent's `AXWindow`s (one per display). The agent's `AXMenuBar` window
    /// duplicates Apple's items, so only `AXWindow` children are read.
    private static func drawnItems(agentPID: pid_t) -> [DrawnItem] {
        let agent = AXUIElementCreateApplication(agentPID)
        var result: [DrawnItem] = []
        for window in children(of: agent) where string(window, kAXRoleAttribute) == kAXWindowRole {
            collectDrawn(in: window, into: &result)
        }
        return result
    }

    /// Third-party items are `AXButton`s; Apple items are `AXMenuBarItem`s. Items aren't descended
    /// into, since their children are menus, not bar items.
    private static func collectDrawn(in element: AXUIElement, into result: inout [DrawnItem]) {
        for child in children(of: element) {
            switch string(child, kAXRoleAttribute) {
            case kAXButtonRole:
                result.append(drawnItem(child, appleIdentifier: nil))
            case kAXMenuBarItemRole:
                let identifier = string(child, kAXIdentifierAttribute)
                result.append(drawnItem(child, appleIdentifier: identifier.isEmpty ? nil : identifier))
            default:
                collectDrawn(in: child, into: &result)
            }
        }
    }

    private static func drawnItem(_ element: AXUIElement, appleIdentifier: String?) -> DrawnItem {
        let frame = frame(of: element)
        return DrawnItem(
            x: frame.minX, width: frame.width,
            label: string(element, kAXDescriptionAttribute) + string(element, kAXTitleAttribute),
            appleIdentifier: appleIdentifier)
    }

    // MARK: Owners

    /// The app's own view of its status items, in the app's order.
    private static func appExtras(pid: pid_t, bundleID: BundleID) -> [AppExtra] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, appTimeout)
        guard let bar = element(app, kAXExtrasMenuBarAttribute) else { return [] }
        AXUIElementSetMessagingTimeout(bar, appTimeout)
        return children(of: bar).enumerated().map { index, item in
            let frame = frame(of: item)
            return AppExtra(
                bundleID: bundleID, indexInApp: index, x: frame.minX, width: frame.width,
                identifier: string(item, kAXIdentifierAttribute),
                title: string(item, kAXTitleAttribute),
                help: string(item, kAXHelpAttribute),
                description: string(item, kAXDescriptionAttribute))
        }
    }

    // MARK: AX helpers (element, children and frame are shared with RevealCoordinator)

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let array = value(element, kAXChildrenAttribute) as? [CFTypeRef] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = axValue(element, kAXPositionAttribute) { AXValueGetValue(position, .cgPoint, &origin) }
        if let extent = axValue(element, kAXSizeAttribute) { AXValueGetValue(extent, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
