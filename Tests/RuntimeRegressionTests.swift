import XCTest

final class RuntimeRegressionTests: XCTestCase {
    @MainActor func testRuntimeTransportAndStorageRegressions() async throws {
        for (name, check) in RuntimeRegressionScenarios.cases {
            do { try await check() }
            catch { XCTFail("\(name): \(error)"); throw error }
        }
    }
}
