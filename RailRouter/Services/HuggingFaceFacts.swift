import Foundation

/// Fiches Hugging Face des modèles Alibaba à poids ouverts (Qwen, DeepSeek, GLM, Kimi) : paramètres exacts et type de modèle.
/// Un seul appel par éditeur, public et sans clé ; résultat gardé 24 h sur disque. Échec ou modèle propriétaire : rien (repli sur le nom).
enum HuggingFaceFacts {
    struct Fact: Codable, Equatable {
        var parameters: Double?
        var capabilities: [String]
    }

    static let authors = ["Qwen", "deepseek-ai", "zai-org", "moonshotai"]
    private static let maxAge: TimeInterval = 24 * 3600

    /// Clé de rapprochement : dernier composant, en minuscules (`Qwen/Qwen3-8B` et `qwen3-8b`).
    static func key(_ id: String) -> String { (id.split(separator: "/").last.map(String.init) ?? id).lowercased() }

    static func label(_ count: Double) -> String {
        count >= 1e12 ? String(format: "%.1fT", count / 1e12) : String(format: "%.0fB", count / 1e9)
    }

    /// `pipeline_tag` → capacités de l'app.
    static func capabilities(pipeline: String?) -> [String] {
        switch pipeline {
        case "image-text-to-text", "visual-question-answering", "image-to-text": return ["vision"]
        case "any-to-any": return ["vision", "audio"]
        case "text-to-image", "image-to-image": return ["image"]
        case "automatic-speech-recognition", "text-to-speech", "audio-text-to-text", "text-to-audio": return ["audio"]
        case "feature-extraction", "sentence-similarity": return ["embedding"]
        default: return []
        }
    }

    /// Réponse de `/api/models?author=…&expand[]=pipeline_tag&expand[]=safetensors`.
    static func decode(_ data: Data) -> [String: Fact] {
        struct Item: Decodable {
            struct Safetensors: Decodable { let total: Double? }
            let id: String
            let pipeline_tag: String?
            let safetensors: Safetensors?
        }
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { return [:] }
        return Dictionary(items.map { (key($0.id), Fact(parameters: $0.safetensors?.total, capabilities: capabilities(pipeline: $0.pipeline_tag))) },
                          uniquingKeysWith: { first, _ in first })
    }

    static func load(session: URLSession = .shared, cache: URL = defaultCache) async -> [String: Fact] {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < maxAge,
           let data = try? Data(contentsOf: cache), let facts = try? JSONDecoder().decode([String: Fact].self, from: data) { return facts }
        var facts: [String: Fact] = [:]
        await withTaskGroup(of: [String: Fact].self) { group in
            for author in authors {
                group.addTask {
                    var components = URLComponents(string: "https://huggingface.co/api/models")!
                    components.queryItems = [.init(name: "author", value: author), .init(name: "limit", value: "1000"),
                                             .init(name: "expand[]", value: "pipeline_tag"), .init(name: "expand[]", value: "safetensors")]
                    var request = URLRequest(url: components.url!)
                    request.timeoutInterval = 10
                    guard let (data, response) = try? await session.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
                    return decode(data)
                }
            }
            for await part in group { facts.merge(part) { first, _ in first } }
        }
        // Pas de cache si un éditeur a échoué (liste partielle) : réessai au prochain rafraîchissement.
        if facts.count > 100, let data = try? JSONEncoder().encode(facts) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache)
        }
        return facts
    }

    static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RailRouter/alibaba-huggingface.json")
    }
}
