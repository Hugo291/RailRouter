import Foundation

/// Catalogue public d'OpenRouter (sans clé) : uniquement les modèles gratuits (`:free`).
actor OpenRouterService {
    private struct Response: Decodable { let data: [Entry] }
    private struct Entry: Decodable {
        struct Architecture: Decodable { let input_modalities: [String]? }
        let id: String
        let name: String?
        let description: String?
        let created: TimeInterval?
        let context_length: Int?
        let architecture: Architecture?
        let supported_parameters: [String]?
    }

    func freeModels() async throws -> [LLMModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try Self.decodeFree(data)
    }

    /// Décode `/api/v1/models` (internal : utilisé par les tests unitaires).
    static func decodeFree(_ data: Data) throws -> [LLMModel] {
        try JSONDecoder().decode(Response.self, from: data).data
            .filter { $0.id.hasSuffix(":free") }
            .map { entry in
                let parameters = Set(entry.supported_parameters ?? [])
                let inputs = Set(entry.architecture?.input_modalities ?? [])
                var capabilities: [String] = []
                if parameters.contains("tools") { capabilities.append("tools") }
                if parameters.contains("reasoning") { capabilities.append("thinking") }
                if inputs.contains("image") { capabilities.append("vision") }
                if inputs.contains("audio") { capabilities.append("audio") }
                if inputs.contains("video") { capabilities.append("video") }
                return LLMModel(
                    id: entry.id,
                    name: entry.id,
                    parameters: Self.parameterLabel(id: entry.id, description: entry.description),
                    quantization: nil,
                    sizeBytes: 0,
                    capabilities: capabilities,
                    modified: entry.created.map { Date(timeIntervalSince1970: $0) },
                    source: .openRouter
                )
            }
    }

    /// OpenRouter ne publie pas de champ « paramètres » : on lit la taille annoncée dans l'identifiant (`…-550b-a55b`),
    /// sinon dans la description (« 280B total », « 12B active »). Résultat : « 550B (A55B) » ; nil si rien n'est annoncé.
    static func parameterLabel(id: String, description: String?) -> String? {
        func first(_ pattern: String, in text: String?) -> String? {
            guard let text, let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return String(text[range])
        }
        func number(_ token: String?) -> String? {
            token.flatMap { first(#"[0-9]+(?:\.[0-9]+)?"#, in: $0) }
        }
        let slug = id.split(separator: "/").last.map(String.init) ?? id
        let total = number(first(#"(?<![a-z0-9.])[0-9]+(?:\.[0-9]+)?(?=b(?![a-z]))"#, in: slug))
            ?? number(first(#"[0-9]+(?:\.[0-9]+)?(?=B total)"#, in: description))
            ?? number(first(#"[0-9]+(?:\.[0-9]+)?(?=B[- ]param)"#, in: description))
            ?? number(first(#"[0-9]+(?:\.[0-9]+)?(?=B-A[0-9])"#, in: description))
        guard let total else { return nil }
        let active = number(first(#"(?<=-a)[0-9]+(?:\.[0-9]+)?(?=b)"#, in: slug))
            ?? number(first(#"[0-9]+(?:\.[0-9]+)?(?=B active)"#, in: description))
            ?? number(first(#"(?<=B-A)[0-9]+(?:\.[0-9]+)?(?=B)"#, in: description))
        if let active, active != total { return "\(total)B (A\(active)B)" }
        return "\(total)B"
    }
}
