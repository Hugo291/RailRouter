import Foundation
import AppKit

final class ModelLibraryTests: XCTestCase {
    private func model(_ name: String, params: String? = nil, quant: String? = nil, size: Int64 = 0, source: LLMModel.ModelSource = .ollama) -> LLMModel {
        LLMModel(id: name, name: name, parameters: params, quantization: quant, sizeBytes: size, capabilities: [], modified: nil, source: source)
    }
    override func runAll() {
        XCTAssertEqual(LLMModel.parameterValue("752.39M"), 752_390_000, accuracy: 0.01)
        XCTAssertEqual(LLMModel.parameterValue("2,81T"), 2_810_000_000_000, accuracy: 1)
        XCTAssertEqual(LLMModel.parameterValue("30B-A3B"), 30_000_000_000)
        XCTAssertNil(LLMModel.parameterValue("—"))
        XCTAssertEqual(LLMModel.bitValue("Q4_K_M"), 4)
        XCTAssertEqual(LLMModel.bitValue("MXFP8"), 8)
        XCTAssertEqual(LLMModel.bitValue("BF16"), 16)
        XCTAssertEqual(LLMModel.bitValue("4-bit"), 4)
        XCTAssertNil(LLMModel.bitValue("unknown2"))
        var roundedA = model("rounded-a", params: "8.1B")
        roundedA.reportedParameterCount = 8_090_000_000
        var roundedB = model("rounded-b", params: "8.1B")
        roundedB.reportedParameterCount = 8_074_934_862
        XCTAssertEqual(ModelLibraryTable.rows([roundedA, roundedB], grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.parametersSortKey)]).compactMap { $0.model?.name }, ["rounded-b", "rounded-a"])
        let parameters = [model("large", params: "2.81T"), model("small", params: "752.39M"), model("medium", params: "27B")]
        XCTAssertEqual(ModelLibraryTable.rows(parameters, grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.parametersSortKey)]).compactMap { $0.model?.name }, ["small", "medium", "large"])
        XCTAssertEqual(ModelLibraryTable.rows(parameters, grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.parametersSortKey, order: .reverse)]).compactMap { $0.model?.name }, ["large", "medium", "small"])
        let expanded = ModelLibraryTable.rows(parameters, grouping: .parameters, sortOrder: [KeyPathComparator(\LLMModel.name)])
        let firstGroup = expanded.first { $0.groupKey != nil }!.groupKey!
        let folded = ModelLibraryTable.rows(parameters, grouping: .parameters, sortOrder: [KeyPathComparator(\LLMModel.name)], collapsed: [firstGroup])
        XCTAssertTrue(folded.count < expanded.count, "Une catégorie repliée masque ses modèles")
        XCTAssertTrue(folded.first { $0.groupKey == firstGroup }?.collapsed == true, "L'en-tête reste visible, marqué replié")
        let quants = [model("16", quant: "F16"), model("8", quant: "Q8_0"), model("4", quant: "Q4_K_M")]
        XCTAssertEqual(ModelLibraryTable.rows(quants, grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.quantizationSortKey)]).compactMap { $0.model?.name }, ["4", "8", "16"])
        let sizes = [model("big", size: 20_000_000_000), model("tiny", size: 800_000_000), model("middle", size: 2_000_000_000)]
        XCTAssertEqual(ModelLibraryTable.rows(sizes, grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.sizeBytes)]).compactMap { $0.model?.name }, ["tiny", "middle", "big"])
        XCTAssertTrue(ModelGrouping.parameters.key(parameters[1]) < ModelGrouping.parameters.key(parameters[2]))
        XCTAssertTrue(ModelGrouping.parameters.key(parameters[2]) < ModelGrouping.parameters.key(parameters[0]))
        XCTAssertEqual(ModelGrouping.quantization.key(quants[2]), ModelGrouping.quantization.key(model("other", quant: "MXFP4")))
        XCTAssertEqual(ModelGrouping.size.label(sizes[1]), "Moins de 1 Go")
        let cloud = model("cloud", size: 200, source: .cloud)
        XCTAssertNil(cloud.localSize)
        XCTAssertEqual(cloud.librarySource, "Ollama")
        let grouped = ModelLibraryTable.rows([cloud, sizes[0]], grouping: .source, sortOrder: [KeyPathComparator(\LLMModel.name)])
        XCTAssertEqual(grouped.filter { $0.title != nil }.count, 1)
        XCTAssertEqual(grouped.compactMap { $0.model?.name }, ["big", "cloud"])
        let unknown = model("unknown")
        XCTAssertEqual(ModelLibraryTable.rows(parameters + [unknown], grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.parametersSortKey)]).last?.model?.name, "unknown")
        XCTAssertEqual(ModelLibraryTable.rows(parameters + [unknown], grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.parametersSortKey, order: .reverse)]).last?.model?.name, "unknown")
        XCTAssertEqual(ModelLibraryTable.rows(sizes + [cloud], grouping: .none, sortOrder: [KeyPathComparator(\LLMModel.sizeSortKey)]).last?.model?.name, "cloud")
        let ollamaQwen = model("qwen3.8:27b")
        let lmQwen = model("qwen/qwen3.8-27b", source: .lmStudio)
        let splash = model("qwen3.8-27b-splash", source: .lmStudio)
        let loaded = ModelInstance(modelName: ollamaQwen.id, engine: .ollama, ram_MB: 100, pid: nil, loadedAt: .now, status: .active)
        XCTAssertEqual(LLMModel.libraryModel(for: loaded, in: [ollamaQwen, lmQwen, splash])?.id, ollamaQwen.id)
        XCTAssertNil(LLMModel.libraryModel(for: loaded, in: [lmQwen, splash]))
        let lmLoaded = ModelInstance(modelName: splash.id, engine: .lmStudio, ram_MB: 100, pid: nil, loadedAt: .now, status: .active)
        XCTAssertEqual(LLMModel.libraryModel(for: lmLoaded, in: [ollamaQwen, lmQwen, splash])?.id, splash.id)
        XCTAssertEqual(ModelIcon.glyph(for: cloud), "cloud.fill")
        XCTAssertEqual(ModelIcon.glyph(for: ollamaQwen), "cube.fill")
        XCTAssertEqual(CapabilityIcons.glyph(for: "tool_use"), CapabilityIcons.glyph(for: "tools"))
        XCTAssertEqual(CapabilityIcons.glyph(for: "reasoning"), CapabilityIcons.glyph(for: "thinking"))
        let capabilities = ["vision", "tools", "audio", "image", "embedding", "completion", "thinking", "video", "decision"]
        XCTAssertEqual(Set(capabilities.map { CapabilityIcons.glyph(for: $0) }).count, capabilities.count)
        for capability in capabilities {
            XCTAssertNotNil(NSImage(systemSymbolName: CapabilityIcons.glyph(for: capability), accessibilityDescription: nil))
        }
        XCTAssertFalse(CapabilityIcons.glyph(for: "embedding") == "textformat")
    }
}
