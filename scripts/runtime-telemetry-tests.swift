import Foundation

@main
struct RuntimeTelemetryChecks {
    static func main() async throws {
        let result = try await RuntimeTelemetryTests.evaluate(smoke: CommandLine.arguments.contains("--smoke"))
        for failure in result.failures { print("FAIL: \(failure)") }
        print("Runtime telemetry: \(result.checks) checks, \(result.failures.count) failures")
        if !result.failures.isEmpty { exit(1) }
    }
}
