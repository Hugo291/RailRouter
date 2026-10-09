import Foundation

final class GatewayActivityTests: XCTestCase {
    override func runAll() {
        let now = Date()
        var instances = [ModelInstance(modelName: "org/model", engine: .mlxDirect, ram_MB: 10, pid: 987654, loadedAt: now, status: .active)]
        var active = GatewayRequestTelemetry(id: UUID(), path: "/v1/responses", model: "mlx/org/model", upstreamModel: "org/model", source: "mlx")
        active.startedAt = now.addingTimeInterval(-10)
        GatewayActivity.apply([active], to: &instances, now: now)
        XCTAssertEqual(instances[0].gatewayRequestStage, "REQUÊTE TRANSMISE")
        XCTAssertTrue(instances[0].lastPrediction == nil)
        active.phase = "completed"
        active.finishedAt = now.addingTimeInterval(-1)
        active.promptTokens = 123
        active.completionTokens = 45
        instances[0].gatewayRequestStage = nil
        GatewayActivity.apply([active], to: &instances, now: now)
        XCTAssertEqual(instances[0].lastPrediction?.promptTokens, 123)
        XCTAssertEqual(instances[0].lastPrediction?.generatedTokens, 45)
        XCTAssertEqual(instances[0].lastPrediction?.source, "Endpoint TchouTchou")
        XCTAssertTrue(instances[0].gatewayRequestStage == nil)
        var ambiguous = instances + instances
        ambiguous[0].lastPrediction = nil
        ambiguous[1].lastPrediction = nil
        GatewayActivity.apply([active], to: &ambiguous, now: now)
        XCTAssertTrue(ambiguous.allSatisfy { $0.lastPrediction == nil })
        var legacy = GatewayRequestTelemetry(id: UUID(), path: "/v1/responses", model: "org/model", upstreamModel: "org/model", source: "legacy")
        legacy.startedAt = now.addingTimeInterval(-1)
        instances[0].lastPrediction = nil
        GatewayActivity.apply([legacy], to: &instances, now: now)
        XCTAssertTrue(instances[0].gatewayRequestStage == nil && instances[0].lastPrediction == nil)
        let data = Data(#"{"server":{"loaded_model":"org/model","effective_context_limit":262144},"latest":{"model":"org/model","timestamp_unix":1791483814,"prompt_tokens":355,"completion_tokens":1046,"decode_tok_s":15.34}}"#.utf8)
        MLXProcessMonitor.applyMetrics(data, to: &instances[0], expectedModel: "org/model")
        XCTAssertEqual(instances[0].lastPrediction?.promptTokens, 355)
        XCTAssertEqual(instances[0].lastPrediction?.generatedTokens, 1046)
        XCTAssertEqual(instances[0].contextLength, 262144)
        XCTAssertEqual(instances[0].lastPrediction?.source, "MLX · /v1/metrics")
        instances[0].lastPrediction = nil
        MLXProcessMonitor.applyMetrics(data, to: &instances[0], expectedModel: "other/model")
        XCTAssertTrue(instances[0].lastPrediction == nil)
    }
}

final class UnifiedGatewaySuite: XCTestCase {
    override func runAll() {
        let result = runSync {
            do { return try await UnifiedGatewayTests.evaluate() }
            catch { return (checks: 0, failures: [String(describing: error)]) }
        }
        checks += result.checks
        for message in result.failures { fail(message, #fileID, #line) }
    }
}
