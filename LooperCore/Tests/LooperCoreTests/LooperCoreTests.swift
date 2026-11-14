import Testing
@testable import LooperCore

@Test func engineVersionIsSet() {
    #expect(!LooperCore.version.isEmpty)
}
