import Foundation

final class RuntimeTelemetryTests: XCTestCase {
    override func runAll() {
        let result = runSync {
            do { return try await Self.evaluate() }
            catch { return (checks: 0, failures: [String(describing: error)]) }
        }
        checks += result.checks
        for message in result.failures { fail(message, #fileID, #line) }
    }

    static func evaluate(smoke: Bool = false) async throws -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        func log(_ stats: String, identifier: String = "instance-a", timestamp: Double = now.timeIntervalSince1970 * 1000) -> Data {
            Data("{\"timestamp\":\(timestamp),\"data\":{\"type\":\"llm.prediction.output\",\"modelIdentifier\":\"\(identifier)\",\"output\":\"discard me\",\"stats\":\(stats)}}".utf8)
        }
        func serverLog(_ content: String) -> Data {
            Data("{\"timestamp\":1,\"data\":{\"type\":\"server.log\",\"content\":\"\(content)\",\"level\":\"info\"}}".utf8)
        }
        let progress = PromptProgress.decode(serverLog("[2026-10-08 22:24:40][INFO][llama-3.2-1b-instruct] Prompt processing progress: 53.9%"))
        check(progress?.identifier == "llama-3.2-1b-instruct" && progress?.percent == 53.9, "Server log prompt progress")
        check(PromptProgress.decode(serverLog("[2026-10-08 22:24:40][INFO] Returning {}")) == nil, "Other server logs ignored")
        check(PromptProgress.decode(serverLog("[x][INFO][m] Prompt processing progress: 140%")) == nil, "Out-of-range progress rejected")
        let line = log(#"{"promptTokensCount":120,"predictedTokensCount":32,"tokensPerSecond":14.5}"#)
        let decoded = PredictionTelemetry.decodeLMStudioLog(line)!
        check(decoded.identifier == "instance-a", "Exact runtime identifier")
        check(decoded.stats.promptTokens == 120 && decoded.stats.generatedTokens == 32, "Measured token counts")
        check(decoded.stats.tokensPerSecond == 14.5 && decoded.stats.completedAt == now, "Speed and epoch milliseconds")
        check(PredictionTelemetry.decodeLMStudioLog(log("null")) == nil, "Missing stats stay unavailable")
        check(PredictionTelemetry.decodeLMStudioLog(log("{}")) == nil, "Empty stats are not zero")
        check(PredictionTelemetry.decodeLMStudioLog(log(#"{"predictedTokensCount":-1,"tokensPerSecond":-5}"#)) == nil, "Invalid values are not counters")
        check(PredictionTelemetry.decodeLMStudioLog(log(#"{"predictedTokensCount":0}"#))?.stats.generatedTokens == 0, "Measured zero is valid")
        check(PredictionTelemetry.decodeLMStudioLog(Data("not JSON".utf8)) == nil, "CLI startup text ignored")
        let input = String(decoding: line, as: UTF8.self).replacingOccurrences(of: "llm.prediction.output", with: "llm.prediction.input")
        check(PredictionTelemetry.decodeLMStudioLog(Data(input.utf8)) == nil, "Inputs do not supply prediction stats")

        let observer = LMStudioTelemetry()
        _ = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        await observer.ingest(line.prefix(31), now: now)
        var snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions.isEmpty, "Incomplete frame not published")
        await observer.ingest(line.dropFirst(31) + Data([10]), now: now)
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions["instance-a"] == decoded.stats, "Chunked NDJSON")
        await observer.ingest(log(#"{"predictedTokensCount":999}"#, timestamp: (now.timeIntervalSince1970 - 1) * 1000) + Data([10]), now: now)
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions["instance-a"] == decoded.stats, "Out-of-order events do not overwrite newer results")
        await observer.ingest(log(#"{"predictedTokensCount":999}"#, identifier: "other") + Data([10]), now: now)
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions.count == 1, "Ignore other/unloaded identifiers")
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now.addingTimeInterval(301))
        check(snapshot.predictions.isEmpty, "Old stats expire")
        await observer.ingest(line + Data([10]), now: now)
        _ = await observer.snapshot(activeIdentifiers: [], now: now)
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions.isEmpty, "Unload/reload removes old results")
        await observer.ingest(Data(repeating: 65, count: 8 * 1024 * 1024 + 1) + Data([10]) + line + Data([10]), now: now)
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions["instance-a"] == decoded.stats, "Oversized frames discarded, next frame recovered")
        await observer.stop()
        snapshot = await observer.snapshot(activeIdentifiers: ["instance-a"], now: now)
        check(snapshot.predictions.isEmpty, "Stop clears results")

        func ps(_ state: String, processed: Int = 63, total: Int = 100, identifier: String = "instance-a") -> Data {
            Data("[{\"identifier\":\"\(identifier)\",\"status\":\"\(state)\",\"processedPromptTokenCount\":\(processed),\"totalPromptTokenCount\":\(total)}]".utf8)
        }
        let busy = LMStudioService.decodeInstances(from: ps("processingPrompt"))[0]
        check(busy.processingPromptPercent == 63 && busy.processedPromptTokens == 63, "Reported prompt progress")
        let idle = LMStudioService.decodeInstances(from: ps("idle"))[0]
        check(idle.processingPromptPercent == nil && idle.processedPromptTokens == nil, "Stale prompt counts hidden at idle")
        check(idle.id == busy.id, "Identity stable across polling and status changes")
        check(busy.id != LMStudioService.decodeInstances(from: ps("generating", identifier: "instance-b"))[0].id, "Distinct loaded instances")
        for counts in [(-1, 100), (101, 100), (0, 0), (1, -1)] {
            check(LMStudioService.decodeInstances(from: ps("processingPrompt", processed: counts.0, total: counts.1))[0].processingPromptPercent == nil, "Invalid progress pair")
        }
        let actualSchema = LMStudioService.decodeInstances(from: Data(#"[{"identifier":"a","status":"processingPrompt","queued":1,"parallel":null}]"#.utf8))[0]
        check(actualSchema.processState == .processingPrompt && actualSchema.processingPromptPercent == nil, "Actual CLI state without invented counts")
        let ollamaJSON = Data(#"{"models":[{"name":"instance-a","size":1,"size_vram":1,"context_length":8192}]}"#.utf8)
        let ollama = try OllamaService.decodePS(ollamaJSON)[0]
        check(ollama.contextLength == 8192 && ollama.processState == .unknown && ollama.lastPrediction == nil, "Ollama context is capacity, activity unavailable")
        check(ollama.id == (try OllamaService.decodePS(ollamaJSON)[0]).id && ollama.id != idle.id, "Stable identity scoped to engine")
        var remote = idle
        remote.runtimeDeviceIdentifier = "remote-device"
        check(remote.id != idle.id, "Identity scoped to runtime device")
        let mlx1 = ModelInstance(modelName: "a", engine: .mlxDirect, ram_MB: 1, pid: 10, loadedAt: now, status: .active)
        let mlx2 = ModelInstance(modelName: "a", engine: .mlxDirect, ram_MB: 1, pid: 11, loadedAt: now, status: .active)
        check(mlx1.id != mlx2.id, "MLX processes distinguished by PID")

        // Simulate parent termination using a sleeping fixture, never a model runtime.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fake-lms")
        let pidFile = directory.appendingPathComponent("child.pid")
        try Data("#!/bin/sh\necho $$ > \"$JEDI_TELEMETRY_TEST_PID\"\nexec /bin/sleep 30\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        let wrapper = Process()
        wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapper.arguments = ["-c", LMStudioTelemetry.observerScript, "telemetry-test", String(parent.processIdentifier), fixture.path]
        wrapper.environment = ProcessInfo.processInfo.environment.merging(["JEDI_TELEMETRY_TEST_PID": pidFile.path]) { _, new in new }
        wrapper.standardOutput = FileHandle.nullDevice
        wrapper.standardError = FileHandle.nullDevice
        defer {
            if parent.isRunning { parent.terminate() }
            if wrapper.isRunning { wrapper.terminate() }
        }
        try wrapper.run()
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        check(FileManager.default.fileExists(atPath: pidFile.path), "Watchdog fixture starts")
        parent.terminate()
        parent.waitUntilExit()
        for _ in 0..<30 {
            if !wrapper.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        check(!wrapper.isRunning, "Wrapper exits after parent termination")
        if let pidText = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            check(kill(pid, 0) == -1 && errno == ESRCH, "Inference observer child is not orphaned")
        } else { check(false, "Watchdog child PID captured") }

        if smoke {
            // Passive subscription only: NEVER calls generate/chat/load/download.
            await observer.start()
            try await Task.sleep(for: .milliseconds(400))
            await observer.stop()
            await observer.start()
            try await Task.sleep(for: .milliseconds(200))
            observer.stopSynchronously()
            await observer.stop()
            print("Passive local lms subscription start/stop completed")
        }
        return (checks, failures)
    }
}
