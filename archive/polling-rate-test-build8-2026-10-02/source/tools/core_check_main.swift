import Foundation

@main struct CoreCheckMain {
    @MainActor static func main() async throws {
        for (name, check) in RuntimeRegressionScenarios.cases {
            do { try await check(); print("PASS: \(name)") }
            catch { print("FAIL: \(name): \(error)"); throw error }
        }
        print("PASS: \(RuntimeRegressionScenarios.cases.count) core regression scenarios")
    }
}
