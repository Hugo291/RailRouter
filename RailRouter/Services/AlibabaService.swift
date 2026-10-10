import Foundation

/// Modèles Alibaba Cloud Model Studio (DashScope) accessibles avec `DASHSCOPE_API_KEY` ; liste vide sans clé.
/// `/v1/models` ne donne que id et date : paramètres et capacités viennent de la fiche Hugging Face quand le modèle
/// a des poids ouverts (`HuggingFaceFacts`), sinon sont déduits du nom (voir `capabilities(id:)`).
actor AlibabaService {
    func models() async -> [LLMModel] {
        let entries = await GatewayAlibaba.entries(session: .shared)
        guard !entries.isEmpty else { return [] }
        async let factsTask = HuggingFaceFacts.load()
        async let pricesTask = AlibabaPricing.load()
        let (facts, prices) = await (factsTask, pricesTask)
        return entries.compactMap { item in
            (item["id"] as? String).map { Self.model(id: $0, created: (item["created"] as? NSNumber)?.doubleValue, facts: facts, prices: prices) }
        }
    }

    /// Identifiant exposé `alibaba/<id>`, comme sur l'endpoint. Quantification : non publiée par le service cloud.
    static func model(id: String, created: TimeInterval? = nil, facts: [String: HuggingFaceFacts.Fact] = [:],
                      prices: [String: TokenPrice] = [:]) -> LLMModel {
        let fact = facts[HuggingFaceFacts.key(id)]
        var model = LLMModel(id: "alibaba/" + id, name: id,
                 parameters: OpenRouterService.parameterLabel(id: id, description: nil),
                 quantization: nil, sizeBytes: 0, capabilities: capabilities(id: id),
                 modified: created.map { Date(timeIntervalSince1970: $0) }, source: .alibaba)
        model.price = AlibabaPricing.price(for: id, in: prices)
        if model.price?.thinking == true, !model.capabilities.contains("thinking") { model.capabilities.append("thinking") }
        guard let fact else { return model }
        if let total = fact.parameters, total > 0 {
            // Total exact de la fiche ; la part active (« A22B ») ne vient que du nom.
            let active = model.parameters.flatMap { label in label.range(of: " (A").map { String(label[$0.lowerBound...]) } }
            model.reportedParameterCount = total
            model.parameters = HuggingFaceFacts.label(total) + (active ?? "")
        }
        model.capabilities = Array(NSOrderedSet(array: fact.capabilities + model.capabilities)) as? [String] ?? model.capabilities
        return model
    }

    /// Déduction par mots du nom : audio (tts/asr/realtime…), image, embedding, vision (vl/omni/ocr/qvq),
    /// raisonnement (thinking/qwq/qvq), outils pour les modèles de discussion.
    static func capabilities(id: String) -> [String] {
        let name = id.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        var result: [String] = []
        if has(["embedding"]) { return ["embedding"] }
        if has(["image", "wan2", "z-image"]) { return ["image"] }
        let audio = has(["tts", "asr", "realtime", "livetranslate", "s2s", "audio", "omni", "tingwu"])
        if audio { result.append("audio") }
        if has(["-vl", "omni", "ocr", "qvq"]) { result.append("vision") }
        if has(["thinking", "qwq", "qvq"]) { result.append("thinking") }
        let chat = !audio || has(["omni"]), notChat = has(["-mt-", "character", "ocr", "ccai", "captioner"])
        if chat && !notChat && !name.contains("realtime") { result.append("tools") }
        return result
    }
}
