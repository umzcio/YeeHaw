import Foundation
import Testing
import YeeHawCore
@testable import YeeHaw

@Suite struct RestoreTests {
    @Test func restoreFlagIsAWritingCommand() {
        guard case .restore? = DebugCommand(arguments: ["YeeHaw", "--restore"]) else {
            Issue.record("--restore not parsed")
            return
        }
        #expect(DebugCommand(arguments: ["YeeHaw", "--restore"])?.isReadOnly == false)
    }

    @Test func everyCatchableQuitSignalQuitsTheOrdinaryWay() {
        #expect(Set(YeeHawApp.quitSignals) == [SIGTERM, SIGINT, SIGHUP, SIGQUIT])
    }

    @Test func failedQuitNamesTheAppsStillOff() {
        let one = StatusItemController.quitFailure(stillOff: ["DigUp"])
        #expect(one.title == "Some icons are still hidden")
        #expect(one.message.contains("switch DigUp back on"))
        #expect(StatusItemController.quitFailure(stillOff: ["DigUp", "Tailscale"]).message.contains("DigUp and Tailscale"))
        #expect(StatusItemController.quitFailure(stillOff: ["A", "B", "C"]).message.contains("A, B and C"))
    }

    @Test func failedQuitWithOnlyAPositionLeftSaysSo() {
        #expect(StatusItemController.quitFailure(stillOff: []).title == "YeeHaw couldn’t put an icon back in place")
    }
}
