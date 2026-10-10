import Foundation

/// Parsing de l'API Ollama — versions 0.35+ (`modified_at` ISO) ET legacy (`modified` unix).
final class OllamaServiceTests: XCTestCase {

    private let tagsJSON = """
    {"models":[
      {"name":"qwen3.8:27b","size":17741872154,"modified_at":"2026-10-08T02:30:11.051547249+02:00","details":{"parameter_size":"27.3B","quantization_level":"Q4_K_M","capabilities":["completion","vision","tools","thinking"]}},
      {"name":"clef:latest","size":1000000,"modified":1791472962,"details":{"parameter_size":"4.2B","quantization_level":"Q8_0","capabilities":["completion"]}},
      {"name":"glm-5.3:cloud","size":0,"modified_at":"2026-10-08T02:00:00+02:00","details":null}
    ]}
    """

    func testTagsParsingModernAndLegacyDates() throws {
        let models = try OllamaService.decodeTags(Data(tagsJSON.utf8))
        XCTAssertEqual(models.count, 3)

        // 0.35+ : "modified_at" ISO avec fractions.
        let qwen = models[0]
        XCTAssertEqual(qwen.name, "qwen3.8:27b")
        XCTAssertEqual(qwen.parameters, "27.3B")
        XCTAssertEqual(qwen.quantization, "Q4_K_M")
        XCTAssertEqual(qwen.sizeBytes, 17_741_872_154)
        XCTAssertTrue(qwen.capabilities.contains("vision"))
        XCTAssertNotNil(qwen.modified)
        XCTAssertEqual(qwen.source, .ollama)

        // Legacy : "modified" timestamp unix (secondes).
        let clef = models[1]
        XCTAssertEqual(clef.modified, Date(timeIntervalSince1970: 1_791_472_962), accuracy: 0.5)

        // ":cloud" → source cloud (jamais « actif » localement).
        XCTAssertEqual(models[2].source, .cloud)
    }

    /// `/api/ps` — état réel du 8 oct. (qwen3.5:0.8b + gemma4:e4b-mlx chargés).
    private let psJSON = """
    {"models":[
      {"name":"qwen3.5:0.8b","size":397284474,"size_vram":397284474,"details":{"parameter_size":"752.39M","quantization_level":"Q8_0"},"expires_at":"2026-10-08T17:23:07.638997+02:00"},
      {"name":"gemma4:e4b-mlx","size":9372019864,"size_vram":9372019864,"details":{"parameter_size":"","quantization_level":""}}
    ]}
    """

    func testPSParsing() throws {
        let instances = try OllamaService.decodePS(Data(psJSON.utf8))
        XCTAssertEqual(instances.count, 2)

        let qwen = instances[0]
        XCTAssertEqual(qwen.modelName, "qwen3.5:0.8b")
        XCTAssertEqual(qwen.engine, .ollama)
        XCTAssertEqual(qwen.ram_MB, 378.86, accuracy: 1)
        XCTAssertEqual(qwen.params, "752.39M")
        XCTAssertEqual(qwen.quantization, "Q8_0")
        // TTL ≥ 0 (peut être nul si le TTL a expiré entre capture et test).
        XCTAssertGreaterThanOrEqual(qwen.ttlMs ?? 0, 0)

        let gemma = instances[1]
        XCTAssertEqual(gemma.modelName, "gemma4:e4b-mlx")
        XCTAssertEqual(gemma.ram_MB, 8_935, accuracy: 5)
        XCTAssertEqual(gemma.params, "")
        XCTAssertNil(gemma.ttlMs)   // pas de expires_at → TTL inconnu
    }

    func testPSEmpty() throws {
        XCTAssertTrue(try OllamaService.decodePS(Data(#"{"models":[]}"#.utf8)).isEmpty)
    }

    func testShowEnrichesMLXMetadata() throws {
        let models = try OllamaService.decodeTags(Data(#"{"models":[{"name":"gemma4:e4b-mlx","size":123,"details":{"parameter_size":"","quantization_level":""}}]}"#.utf8))
        let show = Data(#"{"details":{"parameter_size":"8.1B","quantization_level":"nvfp4"},"model_info":{"general.parameter_count":8074934862,"general.architecture":"gemma4"},"capabilities":["vision","audio"]}"#.utf8)
        let gemma = try OllamaService.enrichModel(models[0], from: show)
        XCTAssertEqual(gemma.parameters, "8.1B")
        XCTAssertEqual(gemma.parameterCount, 8_074_934_862)
        XCTAssertEqual(gemma.quantization, "nvfp4")
        XCTAssertEqual(gemma.quantizationBits, 4)
        XCTAssertTrue(gemma.capabilities.contains("audio"))
        XCTAssertEqual(gemma.sizeBytes, 123)
        let qwen = try OllamaService.enrichModel(models[0], from: Data(#"{"details":{"parameter_size":"852.88M","quantization_level":"mxfp8"},"model_info":{"general.parameter_count":852878912}}"#.utf8))
        XCTAssertEqual(qwen.parameters, "852.88M")
        XCTAssertEqual(qwen.parameterCount, 852_878_912)
        XCTAssertEqual(qwen.quantizationBits, 8)
        let countOnly = try OllamaService.enrichModel(models[0], from: Data(#"{"model_info":{"general.parameter_count":852878912}}"#.utf8))
        XCTAssertEqual(countOnly.parameters, "852.88M")
        let missing = try OllamaService.enrichModel(gemma, from: Data(#"{"details":{"parameter_size":"","quantization_level":""}}"#.utf8))
        XCTAssertEqual(missing.parameters, "8.1B")
        XCTAssertEqual(missing.quantization, "nvfp4")
        XCTAssertEqual(missing.capabilities, gemma.capabilities)
    }

    func testOpenRouterKeepsOnlyFreeModels() throws {
        let json = #"{"data":[{"id":"nvidia/nemotron-3-super-120b-a12b:free","created":1773245239,"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools","reasoning"]},{"id":"openai/gpt-5","architecture":{"input_modalities":["text"]},"supported_parameters":["tools"]}]}"#
        let models = try OpenRouterService.decodeFree(Data(json.utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "nvidia/nemotron-3-super-120b-a12b:free")
        XCTAssertTrue(models[0].source == .openRouter)
        XCTAssertEqual(models[0].capabilities, ["tools", "thinking", "vision"])
        XCTAssertTrue(models[0].localSize == nil)
    }

    func testOpenRouterParameterLabel() {
        let label = OpenRouterService.parameterLabel
        XCTAssertEqual(label("nvidia/nemotron-3-ultra-550b-a55b:free", nil), "550B (A55B)")
        XCTAssertEqual(label("google/gemma-4-31b-it:free", "30.7B dense"), "31B")
        XCTAssertEqual(label("liquid/lfm-2.5-2.6b:free", nil), "2.6B")
        XCTAssertEqual(label("thinkingmachines/inkling-small:free", "12B active parameters out of 276B total"), "276B (A12B)")
        XCTAssertEqual(label("poolside/laguna-xs-2.1:free", "the 33B-A3B category"), "33B (A3B)")
        XCTAssertEqual(label("nvidia/nemotron-3.5-content-safety:free", "A 4B-parameter guard"), "4B")
        XCTAssertTrue(label("apodex/apodex-1.1-mini:free", "A fast model") == nil)
    }

    // Enregistrement pour le runner minimal (main.swift).
    override func runAll() {
        do {
            try testOpenRouterKeepsOnlyFreeModels()
            testOpenRouterParameterLabel()
            try testTagsParsingModernAndLegacyDates()
            try testPSParsing()
            try testPSEmpty()
            try testShowEnrichesMLXMetadata()
        } catch {
            fail("exception non gérée: \(error)", #fileID, #line)
        }
    }
}
