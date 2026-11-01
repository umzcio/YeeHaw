import AppKit
import ApplicationServices
import os
import YeeHawCore

/// The first-run steps, in order (spec "First run").
enum OnboardingStep: Int, CaseIterable, Identifiable, Comparable {
    case accessibility, allowList, layoutFile, review, placeIcon

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What onboarding asks of the Mac.
@MainActor
protocol OnboardingSystem: SwitchedOffSource {
    func isTrusted() -> Bool
    func hasGrant(_ file: GrantedFile) -> Bool
    func requestGrant(_ file: GrantedFile) async -> Bool
    func openAccessibilitySettings()
    /// Writes YeeHaw's own position key just left of Control Center.
    func placeOwnIcon() async throws
    /// Whether YeeHaw's drawn icon is immediately left of Control Center right now.
    func ownIconIsPlaced() async -> Bool
}

/// The onboarding window's state. Each step is done when the Mac says so (Accessibility, the two
/// grants), when the user has acted (the review, YeeHaw's place), or when there's nothing to do
/// (no switched-off apps, the icon already next to Control Center). The current step is the first
/// one not done; finished steps can be opened again to look at.
@MainActor
@Observable
final class OnboardingModel {
    enum Placement: Equatable { case pending, placed, skipped }

    let review: SwitchedOffReviewModel
    private(set) var trusted = false
    private(set) var granted: Set<GrantedFile> = []
    private(set) var reviewed = false
    private(set) var placement: Placement = .pending
    private(set) var isPlacing = false
    /// A grant whose open panel was cancelled or answered with another file.
    private(set) var grantRefused: GrantedFile?
    private(set) var placementError: String?
    /// A finished step the user opened again; nil follows the current step.
    private(set) var selected: OnboardingStep?

    /// Called once when Accessibility turns on (the user is in System Settings), so the window
    /// can come back to the front.
    @ObservationIgnored var onTrusted: (() -> Void)?
    /// Called by Done.
    @ObservationIgnored var onFinish: (() -> Void)?

    @ObservationIgnored private let system: OnboardingSystem
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "onboarding")

    init(system: OnboardingSystem) {
        self.system = system
        review = SwitchedOffReviewModel(source: system)
    }

    /// Reads where the Mac stands. Call once when the window opens.
    func start() async {
        trusted = system.isTrusted()
        granted = Set([GrantedFile.allowList, .positions].filter(system.hasGrant))
        if granted.contains(.allowList) { review.reload() }
        if granted.contains(.positions), await system.ownIconIsPlaced() { placement = .placed }
        Self.log.notice("Onboarding opened at step \(self.current.map { String($0.number) } ?? "done", privacy: .public)")
    }

    /// Polls Accessibility, which only changes in System Settings.
    func tick() {
        let now = system.isTrusted()
        guard now != trusted else { return }
        trusted = now
        if now {
            if selected == .accessibility { selected = nil }
            onTrusted?()
        }
    }

    // MARK: Steps

    func isDone(_ step: OnboardingStep) -> Bool {
        switch step {
        case .accessibility: trusted
        case .allowList: granted.contains(.allowList)
        case .layoutFile: granted.contains(.positions)
        case .review: reviewed || (review.loaded && review.apps.isEmpty)
        case .placeIcon: placement != .pending
        }
    }

    var current: OnboardingStep? { OnboardingStep.allCases.first { !isDone($0) } }
    var isComplete: Bool { current == nil }
    /// The step shown open: a reopened finished step, else the current one.
    var expanded: OnboardingStep? { selected ?? current }

    /// Opens a finished step, or closes it again; the step in progress goes back to itself. Steps
    /// after the current one can't be opened.
    func select(_ step: OnboardingStep) {
        if selected == step || step == current {
            selected = nil
        } else if isDone(step) {
            selected = step
        }
    }

    // MARK: Actions

    func openAccessibility() {
        system.openAccessibilitySettings()
    }

    func requestGrant(_ file: GrantedFile) async {
        if await system.requestGrant(file) {
            granted.insert(file)
            grantRefused = nil
            if file == .allowList { review.reload() }
            if selected == step(for: file) { selected = nil }
        } else {
            grantRefused = file
        }
    }

    /// Adopts the ticked apps (none is fine) and moves on.
    func finishReview() async {
        guard await review.commit() else { return }
        reviewed = true
        if selected == .review { selected = nil }
    }

    func placeIcon() async {
        guard granted.contains(.positions), !isPlacing else { return }
        isPlacing = true
        defer { isPlacing = false }
        do {
            try await system.placeOwnIcon()
            placement = .placed
            placementError = nil
            if selected == .placeIcon { selected = nil }
        } catch ControllerError.unresolvedNeighbor {
            placementError = "macOS hasn’t recorded where Control Center is, so YeeHaw can’t place its icon next to it."
        } catch {
            placementError = "YeeHaw couldn’t change the menu bar layout."
            Self.log.error("Placing YeeHaw's icon failed: \(error, privacy: .public)")
        }
    }

    func skipPlacement() {
        placement = .skipped
        placementError = nil
    }

    func finish() {
        guard isComplete else { return }
        onFinish?()
    }

    private func step(for file: GrantedFile) -> OnboardingStep {
        file == .allowList ? .allowList : .layoutFile
    }
}

/// Onboarding against the real Mac: the controller, the grants and Accessibility.
@MainActor
final class LiveOnboardingSystem: OnboardingSystem {
    private let controller: MenuBarController
    private let grants: FileGrantStore

    init(controller: MenuBarController, grants: FileGrantStore) {
        self.controller = controller
        self.grants = grants
    }

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func hasGrant(_ file: GrantedFile) -> Bool {
        guard let url = grants.url(for: file) else { return false }
        url.stopAccessingSecurityScopedResource()
        return true
    }

    func requestGrant(_ file: GrantedFile) async -> Bool { await grants.requestGrant(for: file) }

    func openAccessibilitySettings() {
        if let url = AppPermission.accessibility.settingsURL { NSWorkspace.shared.open(url) }
    }

    func switchedOff() throws -> [SwitchedOffApp] {
        try controller.userOwnedOff().map {
            SwitchedOffApp(id: $0, name: AppIdentity.name(of: $0), isInstalled: AppIdentity.isInstalled($0))
        }
    }

    func adopt(_ ids: [BundleID]) async throws {
        try await controller.adopt(ids)
        LayoutWindowController.current?.allowListChanged()
    }

    func placeOwnIcon() async throws {
        try await controller.placeOwnIcon(OwnIconLocator.bundleID, name: StatusItemController.autosaveName)
    }

    func ownIconIsPlaced() async -> Bool {
        await controller.refresh()
        return OwnIconPlacement.isNextToControlCenter(controller.items, ownID: OwnIconLocator.bundleID)
    }
}

/// Whether onboarding has been finished, in YeeHaw's defaults.
enum OnboardingRecord {
    static let key = "onboardingComplete"

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
