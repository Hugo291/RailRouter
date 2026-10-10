import Foundation

/// Parsing du CLI `lms` (LM Studio 0.4.x) — schéma réel capturé sur machine.
final class LMStudioServiceTests: XCTestCase {

    /// `lms ps --json` — état réel : Qwen3.8 27B Splash chargé (backend splash).
    private let psIdle = """
    [{"type":"llm","modelKey":"qwen3.8-27b-splash","format":"yuzu","displayName":"Qwen3.8 27B Splash","publisher":"incoai","path":"incoai/Qwen3.8-27B-Splash","sizeBytes":17382672684,"indexedModelIdentifier":"incoai/Qwen3.8-27B-Splash","deviceIdentifier":null,"paramsString":"27B","architecture":"qwen3_5","quantization":{"name":"4bit","bits":4},"identifier":"qwen3.8-27b-splash","ttlMs":60000,"lastUsedTime":1791472962714,"vision":true,"trainedForToolUse":true,"maxContextLength":262144,"contextLength":262144,"status":"idle","queued":0,"parallel":null}]
    """

    /// `lms ps --json` — modèle en cours de préfill (63 % du prompt traité).
    private let psBusy = """
    [{"type":"llm","modelKey":"gemma-4-e4b-it-mlx","displayName":"Gemma 4 E4B IT","sizeBytes":9372019864,"identifier":"gemma-4-e4b-it-mlx","ttlMs":300000,"vision":false,"trainedForToolUse":false,"status":"processingPrompt","processedPromptTokenCount":630,"totalPromptTokenCount":1000,"contextLength":8192}]
    """

    func testPSIdleParsing() {
        let instances = LMStudioService.decodeInstances(from: Data(psIdle.utf8))
        XCTAssertEqual(instances.count, 1)
        let i = instances[0]
        XCTAssertEqual(i.modelName, "qwen3.8-27b-splash")
        XCTAssertEqual(i.displayName, "Qwen3.8 27B Splash")
        XCTAssertEqual(i.engine, .lmStudio)
        XCTAssertEqual(i.sizeBytes, 17_382_672_684)
        XCTAssertEqual(i.ram_MB, Double(17_382_672_684) / (1024 * 1024), accuracy: 1)
        XCTAssertEqual(i.processState, .idle)
        XCTAssertFalse(i.processState.isBusy)
        XCTAssertNil(i.processingPromptPercent)
        XCTAssertEqual(i.vision, true)
        XCTAssertEqual(i.tools, true)
        XCTAssertEqual(i.quantization, "4bit")
        XCTAssertEqual(i.params, "27B")
        XCTAssertEqual(i.contextLength, 262_144)
        XCTAssertEqual(i.ttlMs, 60_000, accuracy: 1)
        XCTAssertNotNil(i.lastUsedTime)
    }

    func testPSBusyParsingWithPercent() {
        let instances = LMStudioService.decodeInstances(from: Data(psBusy.utf8))
        XCTAssertEqual(instances.count, 1)
        let i = instances[0]
        XCTAssertEqual(i.processState, .processingPrompt)
        XCTAssertTrue(i.processState.isBusy)
        XCTAssertEqual(i.processingPromptPercent, 63.0, accuracy: 0.5)
        XCTAssertEqual(i.sizeLabel, "8.73 GB")
    }

    func testEmptyPS() {
        XCTAssertTrue(LMStudioService.decodeInstances(from: Data("[]".utf8)).isEmpty)
    }

    func testMalformedJSONYieldsEmpty() {
        XCTAssertTrue(LMStudioService.decodeInstances(from: Data("not json".utf8)).isEmpty)
    }

    /// `lms ls --json` — bibliothèque avec tailles disque.
    private let lsJSON = """
    [{"type":"llm","modelKey":"qwen3.8-27b-splash","format":"yuzu","displayName":"Qwen3.8 27B Splash","publisher":"incoai","sizeBytes":17382672684,"paramsString":"27B","quantization":{"name":"4bit","bits":4},"vision":true,"trainedForToolUse":true,"maxContextLength":262144},
     {"type":"llm","modelKey":"nvidia-nemotron-3-nano-30b-a3b-mlx","displayName":"NVIDIA Nemotron 3 Nano 30B A3B","publisher":"lmstudio-community","sizeBytes":17792595367,"paramsString":"30B","quantization":{"name":"4bit","bits":4},"vision":false,"trainedForToolUse":true,"maxContextLength":262144},
     {"type":"embeddings","modelKey":"text-embedding-nomic-embed-text-v1.5","displayName":"Nomic Embed Text V1.5","publisher":"nomic-ai","sizeBytes":560000000,"quantization":{"name":"Q4_K_M"},"vision":false,"trainedForToolUse":false}]
    """

    func testLibraryParsing() {
        let models = LMStudioService.decodeLibrary(from: Data(lsJSON.utf8))
        XCTAssertEqual(models.count, 3)

        let qwen = models.first { $0.id == "qwen3.8-27b-splash" }!
        XCTAssertEqual(qwen.name, "Qwen3.8 27B Splash")
        XCTAssertEqual(qwen.parameters, "27B")
        XCTAssertEqual(qwen.quantization, "4bit")
        XCTAssertEqual(qwen.sizeBytes, 17_382_672_684)
        XCTAssertTrue(qwen.capabilities.contains("vision"))
        XCTAssertTrue(qwen.capabilities.contains("tools"))
        XCTAssertEqual(qwen.source, .lmStudio)

        let nomic = models.first { $0.id == "text-embedding-nomic-embed-text-v1.5" }!
        XCTAssertTrue(nomic.capabilities.contains("embedding"))
        XCTAssertFalse(nomic.capabilities.contains("vision"))
        XCTAssertNil(nomic.parameters)
        XCTAssertNil(nomic.reportedParameterCount)
        XCTAssertNil(nomic.modified)
    }

    private func withFixture(_ body: (URL) throws -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LMStudioTests-\(UUID().uuidString)")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { fail("Fixture cleanup failed: \(error)", #fileID, #line) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body(directory)
        } catch { fail("Fixture failed: \(error)", #fileID, #line) }
    }

    private func write(_ data: Data, at url: URL, date: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    }

    private func libraryModel(path: String?, root: URL, params: String? = nil) throws -> LLMModel? {
        // A misleading name/size must never become a parameter-count heuristic.
        var object: [String: Any] = ["modelKey": "fixture-99B", "type": "embeddings", "sizeBytes": 560_000_000]
        if let path { object["path"] = path }
        if let params { object["paramsString"] = params }
        let data = try JSONSerialization.data(withJSONObject: [object])
        return LMStudioService.decodeLibrary(from: data, modelsRoot: root).first
    }

    private func integer(_ value: UInt64, width: Int = 8) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func ggufString(_ value: String) -> Data {
        integer(UInt64(value.utf8.count)) + Data(value.utf8)
    }

    private func gguf(dimensions: [[UInt64]], parameterCount: UInt64? = nil, countType: UInt64 = 10) -> Data {
        var data = Data("GGUF".utf8) + integer(3, width: 4)
        data += integer(UInt64(dimensions.count))
        data += integer(parameterCount == nil ? 1 : 2)
        // Real headers contain string arrays (e.g. tokenizer tokens) before tensor descriptors.
        data += ggufString("tokenizer.ggml.tokens") + integer(9, width: 4)
        data += integer(8, width: 4) + integer(2) + ggufString("one") + ggufString("two")
        if let parameterCount {
            data += ggufString("general.parameter_count") + integer(countType, width: 4)
            data += integer(parameterCount, width: countType == 4 ? 4 : 8)
        }
        for (index, shape) in dimensions.enumerated() {
            data += ggufString("tensor.\(index)") + integer(UInt64(shape.count), width: 4)
            for dimension in shape { data += integer(dimension) }
            data += integer(12, width: 4) + integer(0) // Q4_K: count is independent of quantization.
        }
        return data
    }

    func testModelRootsAndPathResolution() {
        withFixture { home in
            let settings = home.appendingPathComponent(".lmstudio/settings.json")
            let fallback = home.appendingPathComponent(".lmstudio/models")
            XCTAssertEqual(LMStudioService.modelRoot(homeDirectory: home).path, fallback.path)
            let configured = home.appendingPathComponent("custom/models")
            for path in [configured.path, "~/custom/models", "custom/models"] {
                try write(JSONSerialization.data(withJSONObject: ["downloadsFolder": path]), at: settings)
                let root = LMStudioService.modelRoot(homeDirectory: home)
                XCTAssertEqual(root.path, configured.path)
                let model = configured.appendingPathComponent("publisher/model/weights.gguf")
                XCTAssertEqual(LMStudioService.resolveModelPath("publisher/model/weights.gguf", root: root).path, model.path)
                XCTAssertEqual(LMStudioService.resolveModelPath(model.path, root: root).path, model.path)
                XCTAssertEqual(LMStudioService.resolveModelPath("~/custom/models/publisher/model/weights.gguf", root: root, homeDirectory: home).path, model.path)
            }
            for contents in ["{}", "{\"downloadsFolder\":\"  \"}", "{\"downloadsFolder\":42}", "invalid"] {
                try write(Data(contents.utf8), at: settings)
                XCTAssertEqual(LMStudioService.modelRoot(homeDirectory: home).path, fallback.path)
            }
            let alternate = home.appendingPathComponent("alternate-settings.json")
            try write(Data("{\"downloadsFolder\":\"~/alternate\"}".utf8), at: alternate)
            XCTAssertEqual(LMStudioService.modelRoot(settingsURL: alternate, homeDirectory: home).path, home.appendingPathComponent("alternate").path)
        }
    }

    func testRelativeRootUsesLatestModelFileDate() {
        withFixture { home in
            let settings = home.appendingPathComponent(".lmstudio/settings.json")
            try write(Data("{\"downloadsFolder\":\"~/custom-models\"}".utf8), at: settings)
            let root = LMStudioService.modelRoot(homeDirectory: home)
            let directory = root.appendingPathComponent("publisher/model")
            let weightDate = Date(timeIntervalSince1970: 1_700_000_000)
            let configDate = weightDate.addingTimeInterval(60)
            try write(Data(), at: directory.appendingPathComponent("model.safetensors"), date: weightDate)
            try write(Data("{}".utf8), at: directory.appendingPathComponent("config.json"), date: configDate)
            let noiseDate = configDate.addingTimeInterval(1000)
            for noise in [".cache/config.json", "cache/model.gguf", "downloads/model.gguf", "tmp/config.json",
                          "model.gguf.part", "model.safetensors.tmp", "download.json"] {
                try write(Data(), at: directory.appendingPathComponent(noise), date: noiseDate)
            }
            try FileManager.default.setAttributes([.modificationDate: noiseDate], ofItemAtPath: directory.path)
            let model = try libraryModel(path: "publisher/model", root: root)
            XCTAssertEqual(model?.modified, configDate, accuracy: 1)
            XCTAssertNil(model?.parameters) // Safetensors fallback is optional; no architecture guessing.
            let latestWeight = configDate.addingTimeInterval(120)
            try FileManager.default.setAttributes([.modificationDate: latestWeight], ofItemAtPath: directory.appendingPathComponent("model.safetensors").path)
            XCTAssertEqual(try libraryModel(path: "publisher/model", root: root)?.modified, latestWeight, accuracy: 1)
        }
    }

    func testDefaultRootAndAbsoluteFileDate() {
        withFixture { home in
            let root = LMStudioService.modelRoot(homeDirectory: home)
            let file = root.appendingPathComponent("publisher/model/model.gguf")
            let date = Date(timeIntervalSince1970: 1_700_000_123)
            try write(gguf(dimensions: [[1000, 137_000], [1]]), at: file, date: date)
            for path in ["publisher/model/model.gguf", file.path] {
                let model = try libraryModel(path: path, root: root)
                XCTAssertEqual(model?.modified, date, accuracy: 1)
                XCTAssertEqual(model?.parameters, "137M")
                XCTAssertEqual(model?.reportedParameterCount, 137_000_001)
                XCTAssertEqual(model?.parameterCount, 137_000_001)
            }
        }
    }

    func testGGUFMetadataOverridesTensorSumAndCLIHasPriority() {
        withFixture { root in
            let file = root.appendingPathComponent("model.gguf")
            for countType: UInt64 in [4, 10] {
                try write(gguf(dimensions: [[17]], parameterCount: 123_456_789, countType: countType), at: file)
                let model = try libraryModel(path: file.path, root: root)
                XCTAssertEqual(model?.parameters, "123.46M")
                XCTAssertEqual(model?.reportedParameterCount, 123_456_789)
            }
            let reported = try libraryModel(path: file.path, root: root, params: "27B")
            XCTAssertEqual(reported?.parameters, "27B")
            XCTAssertNil(reported?.reportedParameterCount)
            for placeholder in ["", "—", "unknown"] {
                let fallback = try libraryModel(path: file.path, root: root, params: placeholder)
                XCTAssertEqual(fallback?.parameters, "123.46M")
                XCTAssertEqual(fallback?.reportedParameterCount, 123_456_789)
            }
            // CLI parameters also survive an unreadable/malformed header.
            try write(Data("invalid".utf8), at: file)
            XCTAssertEqual(try libraryModel(path: file.path, root: root, params: "27B")?.parameters, "27B")
        }
    }

    func testDirectoryGGUFFallbackIgnoresCachesAndAmbiguousFiles() {
        withFixture { root in
            let directory = root.appendingPathComponent("publisher/model")
            try write(gguf(dimensions: [[1000, 137_000]]), at: directory.appendingPathComponent("model.gguf"))
            try write(gguf(dimensions: [[99]]), at: directory.appendingPathComponent(".cache/other.gguf"))
            XCTAssertEqual(try libraryModel(path: "publisher/model", root: root)?.reportedParameterCount, 137_000_000)
            try write(gguf(dimensions: [[17]]), at: directory.appendingPathComponent("alternative.gguf"))
            XCTAssertNil(try libraryModel(path: "publisher/model", root: root)?.parameters)
            XCTAssertNil(try libraryModel(path: "publisher/model", root: root)?.reportedParameterCount)
        }
    }

    func testSplashYuzuNestedWeightAndManifestDates() {
        withFixture { root in
            let directory = root.appendingPathComponent("publisher/splash")
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try write(Data(), at: directory.appendingPathComponent("target/layer-1.bin"), date: date)
            try write(Data(), at: directory.appendingPathComponent("draft/model.bin"), date: date.addingTimeInterval(1))
            try write(Data(), at: directory.appendingPathComponent("vision/model.bin"), date: date.addingTimeInterval(2))
            let data = try JSONSerialization.data(withJSONObject: [["modelKey": "splash", "format": "yuzu", "path": "publisher/splash", "paramsString": "27B"]])
            XCTAssertEqual(LMStudioService.decodeLibrary(from: data, modelsRoot: root).first?.modified, date.addingTimeInterval(2), accuracy: 1)
            try write(Data("{}".utf8), at: directory.appendingPathComponent("manifest.json"), date: date.addingTimeInterval(3))
            XCTAssertEqual(LMStudioService.decodeLibrary(from: data, modelsRoot: root).first?.modified, date.addingTimeInterval(3), accuracy: 1)
        }
    }

    func testMissingAndInvalidMetadataStayNil() {
        withFixture { root in
            for path in [nil, "", "missing-99B.gguf"] as [String?] {
                let model = try libraryModel(path: path, root: root)
                XCTAssertNil(model?.modified)
                XCTAssertNil(model?.parameters)
                XCTAssertNil(model?.reportedParameterCount)
            }
            XCTAssertNil(try libraryModel(path: "missing.gguf", root: root, params: "—")?.parameters)
            let empty = root.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            XCTAssertNil(try libraryModel(path: "empty", root: root)?.modified)
            let file = root.appendingPathComponent("invalid.gguf")
            let truncated = Data(gguf(dimensions: [[12, 34]]).dropLast())
            for data in [Data("not GGUF".utf8), truncated, gguf(dimensions: []),
                         gguf(dimensions: [[0]]), gguf(dimensions: [[UInt64.max, 2]]),
                         gguf(dimensions: [[UInt64.max], [1]])] {
                try write(data, at: file)
                let model = try libraryModel(path: file.path, root: root)
                XCTAssertNil(model?.parameters)
                XCTAssertNil(model?.reportedParameterCount)
                XCTAssertNotNil(model?.modified)
            }
            // The declared string would exceed the 16 MiB header budget. Sparse file, no payload allocation.
            var oversized = Data("GGUF".utf8) + integer(3, width: 4) + integer(1) + integer(1)
            oversized += ggufString("large.value") + integer(8, width: 4) + integer(16 * 1024 * 1024)
            try write(oversized, at: file)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 32 * 1024 * 1024)
            XCTAssertNil(try libraryModel(path: file.path, root: root)?.reportedParameterCount)
        }
    }

    func testHubAndBundledIndexResolution() {
        withFixture { home in
            let root = home.appendingPathComponent("downloads")
            let concrete = root.appendingPathComponent("publisher/real-weights")
            let bundled = home.appendingPathComponent("bundled/nomic")
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try write(Data(), at: concrete.appendingPathComponent("model.safetensors"), date: date)
            try write(gguf(dimensions: [[1000, 137_000]]), at: bundled.appendingPathComponent("nomic.gguf"), date: date)
            let index = home.appendingPathComponent("model-index-cache.json")
            let records: [[String: Any]] = [
                ["indexedModelIdentifier": "qwen/virtual", "concreteModelDirAbsolutePath": concrete.path, "containingDirAbsolutePath": home.appendingPathComponent("hub/qwen/virtual").path],
                ["indexedModelIdentifier": "nomic/nomic.gguf", "containingDirAbsolutePath": bundled.path]
            ]
            try write(JSONSerialization.data(withJSONObject: ["models": records]), at: index)
            let entries: [[String: Any]] = [
                ["modelKey": "qwen/virtual", "path": "qwen/virtual", "paramsString": "27B"],
                ["modelKey": "embedding-model", "indexedModelIdentifier": "nomic/nomic.gguf", "path": "nomic/nomic.gguf"]
            ]
            let data = try JSONSerialization.data(withJSONObject: entries)
            let models = LMStudioService.decodeLibrary(from: data, modelsRoot: root, modelIndexURL: index)
            XCTAssertEqual(models.count, 2)
            XCTAssertEqual(models[0].modified, date, accuracy: 1)
            XCTAssertEqual(models[1].modified, date, accuracy: 1)
            XCTAssertEqual(models[1].parameters, "137M")
            XCTAssertEqual(models[1].reportedParameterCount, 137_000_000)
            try FileManager.default.removeItem(at: bundled.appendingPathComponent("nomic.gguf"))
            XCTAssertNil(LMStudioService.decodeLibrary(from: data, modelsRoot: root, modelIndexURL: index)[1].modified)
            XCTAssertNil(LMStudioService.decodeLibrary(from: data, modelsRoot: root, modelIndexURL: index)[1].parameters)
        }
    }

    // Enregistrement pour le runner minimal (main.swift).
    override func runAll() {
        testPSIdleParsing()
        testPSBusyParsingWithPercent()
        testEmptyPS()
        testMalformedJSONYieldsEmpty()
        testLibraryParsing()
        testModelRootsAndPathResolution()
        testRelativeRootUsesLatestModelFileDate()
        testDefaultRootAndAbsoluteFileDate()
        testGGUFMetadataOverridesTensorSumAndCLIHasPriority()
        testDirectoryGGUFFallbackIgnoresCachesAndAmbiguousFiles()
        testSplashYuzuNestedWeightAndManifestDates()
        testMissingAndInvalidMetadataStayNil()
        testHubAndBundledIndexResolution()
    }
}
