import Foundation
import Testing
@testable import YeeHawCore

@Suite struct SpacingPlanTests {
    static let home = "/Users/x"

    static func app(_ id: BundleID, path: String, name: String = "App", windows: Bool = false) -> RunningMenuBarApp {
        RunningMenuBarApp(bundleID: id, bundlePath: path, name: name, hasOpenWindows: windows)
    }

    @Test func excludesAppleAndNonApplications() {
        let apps = [
            Self.app("com.apple.Spotlight", path: "/System/Library/CoreServices/Spotlight.app"),
            Self.app("com.apple.Music", path: "/Applications/Music.app"),
            Self.app("com.example.foo", path: "/Users/x/Downloads/Foo.app"),
        ]
        #expect(SpacingPlan.candidates(apps, own: "com.zapps.yeehaw", home: Self.home).isEmpty)
    }

    @Test func excludesSelf() {
        let apps = [Self.app("com.zapps.yeehaw", path: "/Users/x/Applications/YeeHaw.app")]
        #expect(SpacingPlan.candidates(apps, own: "com.zapps.yeehaw", home: Self.home).isEmpty)
    }

    @Test func menuBarOnlyTickedWindowedUnticked() {
        let digUp = Self.app("com.abdurrahim.DigUp", path: "/Applications/DigUp.app", name: "DigUp")
        let outlook = Self.app("com.microsoft.Outlook", path: "/Applications/Microsoft Outlook.app",
                               name: "Microsoft Outlook", windows: true)
        let result = SpacingPlan.candidates([digUp, outlook], own: "com.zapps.yeehaw", home: Self.home)
        #expect(result == [
            RelaunchCandidate(app: digUp, tickedByDefault: true),
            RelaunchCandidate(app: outlook, tickedByDefault: false),
        ])
    }

    @Test func acceptsBothApplicationsFolders() {
        let system = Self.app("com.example.a", path: "/Applications/A.app")
        let nested = Self.app("com.example.b", path: "/Applications/Utilities/B.app")
        let user = Self.app("com.example.c", path: "/Users/x/Applications/C.app")
        let result = SpacingPlan.candidates([system, nested, user], own: "com.zapps.yeehaw", home: Self.home)
        #expect(result.map(\.app) == [system, nested, user])
    }

    @Test func rejectsLookalikeAndEscapingPaths() {
        let apps = [
            // Another user's Applications folder, a folder merely named like one, and a path
            // that leaves /Applications.
            Self.app("com.example.a", path: "/Users/y/Applications/A.app"),
            Self.app("com.example.b", path: "/ApplicationsOld/B.app"),
            Self.app("com.example.c", path: "/Applications/../Users/x/Downloads/C.app"),
            Self.app("com.example.d", path: "relative/Applications/D.app"),
            Self.app("com.example.e", path: "/Applications/"),
        ]
        #expect(SpacingPlan.candidates(apps, own: "com.zapps.yeehaw", home: Self.home).isEmpty)
    }

    @Test func oneCandidatePerAppInFirstSeenOrder() {
        let a = Self.app("com.example.a", path: "/Applications/A.app")
        let b = Self.app("com.example.b", path: "/Applications/B.app")
        let result = SpacingPlan.candidates([a, b, a], own: "com.zapps.yeehaw", home: Self.home)
        #expect(result.map(\.app.bundleID) == ["com.example.a", "com.example.b"])
    }

    @Test func defaultHomeIsTheUsersOwn() {
        let user = Self.app("com.example.c", path: NSHomeDirectory() + "/Applications/C.app")
        #expect(SpacingPlan.candidates([user], own: "com.zapps.yeehaw").count == 1)
    }

    @Test func clampsIntoRange() {
        #expect(SpacingPlan.clamped(-3) == 0)
        #expect(SpacingPlan.clamped(40) == 32)
        #expect(SpacingPlan.clamped(8) == 8)
    }
}
