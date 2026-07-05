import Testing
@testable import HallE

@Suite("Toolchain smoke")
struct SmokeTests {
    @Test func testingFrameworkWorks() {
        #expect(1 + 1 == 2)
    }
}
