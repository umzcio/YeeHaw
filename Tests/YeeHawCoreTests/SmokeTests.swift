import Testing
@testable import YeeHawCore

@Test func bundleIDAliasIsString() {
    let id: BundleID = "x"
    #expect(id == "x")
}
