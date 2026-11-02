import Foundation
import Testing
import YeeHawCore
@testable import YeeHaw

/// The Mac as onboarding sees it: permission, grants, switched-off apps and YeeHaw's own place.
@MainActor
final class FakeOnboardingSystem: OnboardingSystem {
    var trusted = false
    var grants: Set<GrantedFile> = []
    /// What the next open panel returns.
    var grantAnswer = true
    var switchedOffApps: [SwitchedOffApp] = []
    var switchedOffError: Error?
    var adoptError: Error?
    var placeError: Error?
    var drawnNextToControlCenter = false

    private(set) var grantRequests: [GrantedFile] = []
    private(set) var adopted: [[BundleID]] = []
    private(set) var placements = 0
    private(set) var settingsOpened = 0
    private(set) var placementChecks = 0
    /// Accessibility registrations and pane openings, in order.
    private(set) var accessibilityCalls: [String] = []

    func isTrusted() -> Bool { trusted }
    func hasGrant(_ file: GrantedFile) async -> Bool { grants.contains(file) }
    func requestGrant(_ file: GrantedFile) async -> Bool {
        grantRequests.append(file)
        if grantAnswer { grants.insert(file) }
        return grantAnswer
    }
    func registerWithAccessibility() { accessibilityCalls.append("register") }
    func openAccessibilitySettings() {
        settingsOpened += 1
        accessibilityCalls.append("open")
    }
    func switchedOff() throws -> [SwitchedOffApp] {
        if let switchedOffError { throw switchedOffError }
        return switchedOffApps
    }
    func adopt(_ ids: [BundleID]) async throws {
        if let adoptError { throw adoptError }
        adopted.append(ids)
        switchedOffApps.removeAll { ids.contains($0.id) }
    }
    func placeOwnIcon() async throws {
        if let placeError { throw placeError }
        placements += 1
    }
    func ownIconIsPlaced() async -> Bool {
        placementChecks += 1
        return drawnNextToControlCenter
    }
}

struct Boom: Error {}

@MainActor
@Suite struct SwitchedOffReviewTests {
    static func app(_ name: String) -> SwitchedOffApp {
        SwitchedOffApp(id: "com.example.\(name.lowercased())", name: name)
    }

    static func loaded(_ names: [String]) -> (FakeOnboardingSystem, SwitchedOffReviewModel) {
        let system = FakeOnboardingSystem()
        system.switchedOffApps = names.map(app)
        let review = SwitchedOffReviewModel(source: system)
        review.reload()
        return (system, review)
    }

    @Test func listsEveryAppUntickedByName() {
        let (_, review) = Self.loaded(["OneDrive", "Google Drive", "discord"])
        #expect(review.apps.map(\.name) == ["discord", "Google Drive", "OneDrive"])
        #expect(review.apps.allSatisfy { !$0.ticked })
        #expect(review.loaded)
    }

    @Test func appsThatArentInstalledComeLast() {
        let system = FakeOnboardingSystem()
        system.switchedOffApps = [SwitchedOffApp(id: "com.stablyai.orca", name: "com.stablyai.orca", isInstalled: false),
                                  Self.app("Zoom"), Self.app("Bionic")]
        let review = SwitchedOffReviewModel(source: system)
        review.reload()
        #expect(review.apps.map(\.name) == ["Bionic", "Zoom", "com.stablyai.orca"])
    }

    @Test func committingNothingAdoptsNothing() async {
        let (system, review) = Self.loaded(["OneDrive", "Google Drive"])
        #expect(await review.commit())
        #expect(system.adopted.isEmpty)
        #expect(review.adoptedCount == 0)
    }

    @Test func onlyTickedAppsAreAdopted() async {
        let (system, review) = Self.loaded(["Alpha", "Beta", "Gamma"])
        review.setTicked(true, for: "com.example.gamma")
        review.setTicked(true, for: "com.example.alpha")
        review.setTicked(true, for: "com.example.beta")
        review.setTicked(false, for: "com.example.beta")
        #expect(await review.commit())
        #expect(system.adopted == [["com.example.alpha", "com.example.gamma"]])
        #expect(review.adoptedCount == 2)
        // Adopted apps belong to YeeHaw now and leave the list.
        #expect(review.apps.map(\.name) == ["Beta"])
    }

    @Test func aFailedAdoptKeepsTheTicksAndSaysWhy() async {
        let (system, review) = Self.loaded(["Alpha"])
        system.adoptError = Boom()
        review.setTicked(true, for: "com.example.alpha")
        #expect(await !review.commit())
        #expect(review.apps.first?.ticked == true)
        #expect(review.error != nil)
    }

    @Test func reloadingClearsTicks() {
        let (_, review) = Self.loaded(["Alpha"])
        review.setTicked(true, for: "com.example.alpha")
        review.reload()
        #expect(review.apps.first?.ticked == false)
    }

    @Test func anUnreadableListIsNotLoaded() {
        let system = FakeOnboardingSystem()
        system.switchedOffError = ControllerError.needsGrant(.allowList)
        let review = SwitchedOffReviewModel(source: system)
        review.reload()
        #expect(!review.loaded)
        #expect(review.apps.isEmpty)
        // Says what happened, without promising it resolves on its own.
        #expect(review.error == "YeeHaw couldn’t read the menu bar’s Allow list.")
    }

    @Test func tryingAgainReadsTheListOnceItsReadable() {
        let system = FakeOnboardingSystem()
        system.switchedOffError = ControllerError.malformed(.allowList)
        system.switchedOffApps = [Self.app("Alpha")]
        let review = SwitchedOffReviewModel(source: system)
        review.reload()
        #expect(!review.loaded)
        system.switchedOffError = nil
        review.reload()
        #expect(review.loaded)
        #expect(review.error == nil)
        #expect(review.apps.map(\.name) == ["Alpha"])
    }

    @Test func selectAllTicksEveryAppAndSelectNoneClearsThem() {
        let (_, review) = Self.loaded(["Alpha", "Beta", "Gamma"])
        #expect(!review.allTicked)
        review.setAllTicked(true)
        #expect(review.allTicked)
        #expect(review.tickedIDs.count == 3)
        review.setTicked(false, for: "com.example.beta")
        #expect(!review.allTicked)
        review.setAllTicked(false)
        #expect(review.tickedIDs.isEmpty)
    }

    @Test func theListSaysHowManyAppsAreOff() {
        #expect(Self.loaded(["Alpha"]).1.countTitle == "1 app is switched off")
        #expect(Self.loaded(["Alpha", "Beta"]).1.countTitle == "2 apps are switched off")
        #expect(Self.loaded([]).1.countTitle == nil)
    }

    @Test func commitTitleCountsTicks() {
        let (_, review) = Self.loaded(["Alpha", "Beta"])
        #expect(review.commitTitle == nil)
        review.setTicked(true, for: "com.example.alpha")
        #expect(review.commitTitle == "Move 1 App to Hidden")
        review.setTicked(true, for: "com.example.beta")
        #expect(review.commitTitle == "Move 2 Apps to Hidden")
    }
}

@MainActor
@Suite struct OnboardingModelTests {
    static func model(_ configure: (FakeOnboardingSystem) -> Void = { _ in }) async -> (FakeOnboardingSystem, OnboardingModel) {
        let system = FakeOnboardingSystem()
        configure(system)
        let model = OnboardingModel(system: system)
        await model.start()
        return (system, model)
    }

    @Test func aCleanMacStartsAtAccessibility() async {
        let (_, model) = await Self.model()
        #expect(model.current == .accessibility)
        #expect(model.expanded == .accessibility)
        #expect(!model.isComplete)
        #expect(OnboardingStep.allCases.allSatisfy { !model.isDone($0) })
    }

    @Test func satisfiedStepsShowAsDone() async {
        let (_, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
            $0.switchedOffApps = [SwitchedOffReviewTests.app("OneDrive")]
        }
        #expect(model.isDone(.accessibility))
        #expect(model.isDone(.allowList))
        #expect(model.isDone(.layoutFile))
        #expect(model.current == .review)
        #expect(model.review.apps.map(\.name) == ["OneDrive"])
    }

    @Test func openingAccessibilityRegistersYeeHawBeforeOpeningThePane() async {
        // Registering puts YeeHaw in the Accessibility list, so the pane has a row to turn on.
        let (system, model) = await Self.model()
        model.openAccessibility()
        #expect(system.accessibilityCalls == ["register", "open"])
    }

    @Test func accessibilityAdvancesWhenTrustArrives() async {
        let (system, model) = await Self.model()
        model.openAccessibility()
        #expect(system.settingsOpened == 1)
        var advanced = 0
        model.onTrusted = { advanced += 1 }
        model.tick()
        #expect(model.current == .accessibility)
        system.trusted = true
        model.tick()
        model.tick()
        #expect(model.current == .allowList)
        #expect(advanced == 1)
    }

    @Test func grantsAreRequestedAndTheListLoadsAfterTheAllowList() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.switchedOffApps = [SwitchedOffReviewTests.app("OneDrive")]
        }
        #expect(!model.review.loaded)
        await model.requestGrant(.allowList)
        #expect(system.grantRequests == [.allowList])
        #expect(model.review.loaded)
        #expect(model.current == .layoutFile)
        await model.requestGrant(.positions)
        #expect(model.current == .review)
    }

    @Test func aRefusedGrantSaysSoAndStays() async {
        let (system, model) = await Self.model { $0.trusted = true }
        system.grantAnswer = false
        await model.requestGrant(.allowList)
        #expect(model.grantRefused == .allowList)
        #expect(model.current == .allowList)
        system.grantAnswer = true
        await model.requestGrant(.allowList)
        #expect(model.grantRefused == nil)
    }

    @Test func reviewDoneOnlyAfterContinuing() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
            $0.switchedOffApps = [SwitchedOffReviewTests.app("OneDrive"), SwitchedOffReviewTests.app("Google Drive")]
        }
        #expect(model.current == .review)
        await model.finishReview()
        #expect(system.adopted.isEmpty)
        #expect(model.isDone(.review))
        #expect(model.current == .placeIcon)
    }

    @Test func anUnreadableListCanBeContinuedPastWithoutAdoptingAnything() async {
        // Step 2 can be done (the file reads) while the list can't be parsed: the user must not be
        // stuck. Continuing adopts nothing, and the apps can be reviewed later in Settings.
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
            $0.switchedOffError = ControllerError.malformed(.allowList)
        }
        #expect(model.current == .review)
        #expect(!model.review.loaded)
        #expect(model.canFinishReview)
        await model.finishReview()
        #expect(system.adopted.isEmpty)
        #expect(model.isDone(.review))
        #expect(model.current == .placeIcon)
    }

    @Test func tryingAgainWithNothingSwitchedOffFinishesTheReview() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
            $0.switchedOffError = ControllerError.malformed(.allowList)
        }
        #expect(model.current == .review)
        system.switchedOffError = nil
        model.retryReview()
        #expect(model.review.loaded)
        #expect(model.isDone(.review))
        #expect(model.current == .placeIcon)
    }

    @Test func nothingSwitchedOffNeedsNoReview() async {
        let (_, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
        }
        #expect(model.isDone(.review))
        #expect(model.current == .placeIcon)
    }

    @Test func placingTheIconFinishesTheSteps() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
        }
        await model.placeIcon()
        #expect(system.placements == 1)
        #expect(model.isDone(.placeIcon))
        #expect(model.isComplete)
        #expect(model.current == nil)
    }

    @Test func anIconAlreadyNextToControlCenterIsDone() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
            $0.drawnNextToControlCenter = true
        }
        #expect(model.isComplete)
        #expect(system.placements == 0)
    }

    @Test func skippingPlacementLeavesTheIconAlone() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
        }
        model.skipPlacement()
        #expect(system.placements == 0)
        #expect(model.isComplete)
        #expect(model.placement == .skipped)
    }

    @Test func aFailedPlacementSaysWhyAndStays() async {
        let (system, model) = await Self.model {
            $0.trusted = true
            $0.grants = [.allowList, .positions]
        }
        system.placeError = ControllerError.unresolvedNeighbor
        await model.placeIcon()
        #expect(model.current == .placeIcon)
        #expect(model.placementError != nil)
    }

    @Test func placementWaitsForTheLayoutGrant() async {
        let (system, model) = await Self.model { $0.trusted = true; $0.grants = [.allowList] }
        await model.placeIcon()
        #expect(system.placements == 0)
        #expect(system.placementChecks == 0)
    }

    @Test func finishedStepsCanBeReopenedButLaterOnesCannot() async {
        let (_, model) = await Self.model { $0.trusted = true }
        #expect(model.current == .allowList)
        model.select(.accessibility)
        #expect(model.expanded == .accessibility)
        model.select(.accessibility)
        #expect(model.expanded == .allowList)
        model.select(.placeIcon)
        #expect(model.expanded == .allowList)
        // Clicking the step in progress goes back to it.
        model.select(.accessibility)
        model.select(.allowList)
        #expect(model.expanded == .allowList)
    }

    @Test func finishingIsOnlyPossibleWhenComplete() async {
        let (_, model) = await Self.model { $0.trusted = true }
        var finished = 0
        model.onFinish = { finished += 1 }
        model.finish()
        #expect(finished == 0)
        await model.requestGrant(.allowList)
        await model.requestGrant(.positions)
        model.skipPlacement()
        model.finish()
        #expect(finished == 1)
    }
}
