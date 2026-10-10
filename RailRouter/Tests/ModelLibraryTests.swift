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
        let many = (0..<40).map { model(String(format: "m%02d", $0), source: .alibaba) }
        let order = [KeyPathComparator(\LLMModel.name)]
        let paged = ModelLibraryTable.rows(many, grouping: .source, sortOrder: order)
        XCTAssertEqual(paged.compactMap { $0.model }.count, 15)
        XCTAssertEqual(paged.last?.remaining, 25)
        let more = ModelLibraryTable.rows(many, grouping: .source, sortOrder: order, extra: [paged.last?.moreKey ?? "": 15])
        XCTAssertEqual(more.compactMap { $0.model }.count, 30)
        XCTAssertEqual(ModelLibraryTable.rows(many, grouping: .none, sortOrder: order, extra: ["all": 30]).last?.moreKey, nil)
        XCTAssertEqual(AlibabaService.model(id: "qwen3-235b-a22b-thinking-2507").parameters, "235B (A22B)")
        XCTAssertEqual(AlibabaService.capabilities(id: "qwen3-vl-plus"), ["vision", "tools"])
        XCTAssertEqual(AlibabaService.capabilities(id: "qwen3-tts-flash"), ["audio"])
        XCTAssertEqual(AlibabaService.capabilities(id: "qwen-image-2.0"), ["image"])
        XCTAssertEqual(AlibabaService.capabilities(id: "qwen3-coder-plus"), ["tools"])
        XCTAssertEqual(AlibabaService.capabilities(id: "qwen3-omni-flash"), ["audio", "vision", "tools"])
        let hf = HuggingFaceFacts.decode(Data(#"[{"id":"Qwen/Qwen3-235B-A22B","pipeline_tag":"text-generation","safetensors":{"total":235093634560}},{"id":"Qwen/Qwen3-VL-8B-Instruct","pipeline_tag":"image-text-to-text"}]"#.utf8))
        let moe = AlibabaService.model(id: "qwen3-235b-a22b", facts: hf)
        XCTAssertEqual(moe.parameters, "235B (A22B)")
        XCTAssertEqual(moe.reportedParameterCount, 235_093_634_560)
        XCTAssertEqual(AlibabaService.model(id: "qwen3-vl-8b-instruct", facts: hf).capabilities.first, "vision")
        XCTAssertEqual(HuggingFaceFacts.label(2_779_931_837_184), "2.8T")
        let pricing = AlibabaPricing.parse("""
            <h3>China (Beijing)</h3><table><tr><td>Model ID</td><td>Input price (per 1 million tokens)</td><td>Output price (per 1 million tokens)</td></tr>
            <tr><td>qwen-plus</td><td>$0.115</td><td>$0.287</td></tr></table>
            <h3>Singapore</h3><table><tr><th rowspan="2">Model ID</th><th rowspan="2">Deployment scope</th><th rowspan="2">Input price (per 1 million tokens)</th><th colspan="2">Output price (per 1 million tokens)</th></tr>
            <tr><td>Non-Thinking mode</td><td>Thinking mode</td></tr>
            <tr><td rowspan="2">qwen-plus <b>Currently equivalent</b></td><td>International</td><td>List price $0.4 (20% off)</td><td>$1.2</td><td>$4</td></tr>
            <tr><td>kimi-k3</td><td>International</td><td>$3</td><td>$15</td><td>$15</td></tr></table>
            <h3>Singapore</h3><table><tr><td>Model ID</td><td>Price (per image)</td></tr><tr><td>qwen-image</td><td>$0.03</td></tr></table>
            """)
        XCTAssertEqual(pricing["qwen-plus"], TokenPrice(input: 0.4, output: 1.2, thinking: true))
        XCTAssertEqual(pricing["kimi-k3"]?.tier, 3)
        XCTAssertNil(pricing["qwen-image"])
        XCTAssertEqual(AlibabaPricing.price(for: "kimi/kimi-k3", in: pricing)?.input, 3)
        XCTAssertEqual(TokenPrice(input: 0.4, output: 1.2).tier, 1)
        XCTAssertEqual(TokenPrice(input: 1.4, output: 4.4).tier, 2)
        XCTAssertEqual(TokenPrice.compact(TokenPrice(input: 0.2, output: 0.4)), "in 0.2$/out 0.4$")
        XCTAssertEqual(TokenPrice.compact(TokenPrice(input: 0.07, output: nil)), "in 0.07$")
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
