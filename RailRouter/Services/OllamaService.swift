import Foundation

/// Service de communication avec l'API Ollama (localhost:11434)
actor OllamaService {
    
    private let baseURL = AppSettings.ollamaBaseURL
    private struct CachedMetadata {
        let modified: Date?
        let sizeBytes: Int64
        let response: ShowResponse
    }
    private var metadataCache: [String: CachedMetadata] = [:]
    
    // ── CONNEXION ──
    
    func checkConnection() async -> (Bool, String?) {
        do {
            let url = baseURL.appendingPathComponent("api/version")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return (false, nil)
            }
            if let json = try? JSONDecoder().decode(VersionResponse.self, from: data) {
                return (true, json.version)
            }
            return (true, nil)
        } catch {
            return (false, nil)
        }
    }
    
    // ── BIBLIOTHÈQUE ──
    
    func listModels() async -> [LLMModel] {
        guard let url = baseURL.appendingPathComponent("api/tags") as URL? else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return await enrichModels(try Self.decodeTags(data))
        } catch {
            print("⚠️ Ollama listModels error: \(error)")
            return []
        }
    }

    /// /api/tags is incomplete for MLX models. /api/show is authoritative and
    /// cached until the local model's modification date or file size changes.
    func enrichModels(_ models: [LLMModel]) async -> [LLMModel] {
        var enriched = models
        metadataCache = metadataCache.filter { entry in models.contains { $0.id == entry.key } }
        for index in enriched.indices {
            let model = enriched[index]
            let response: ShowResponse?
            if let cached = metadataCache[model.id], cached.modified == model.modified, cached.sizeBytes == model.sizeBytes {
                response = cached.response
            } else {
                response = await fetchMetadata(for: model.id)
                if let response {
                    metadataCache[model.id] = CachedMetadata(modified: model.modified, sizeBytes: model.sizeBytes, response: response)
                }
            }
            if let response { enriched[index] = Self.applying(response, to: model) }
        }
        return enriched
    }

    private func fetchMetadata(for model: String) async -> ShowResponse? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, http) = try? await URLSession.shared.data(for: request),
              (http as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ShowResponse.self, from: data)
    }

    static func enrichModel(_ model: LLMModel, from data: Data) throws -> LLMModel {
        applying(try JSONDecoder().decode(ShowResponse.self, from: data), to: model)
    }

    private static func applying(_ metadata: ShowResponse, to model: LLMModel) -> LLMModel {
        var model = model
        if let capabilities = metadata.capabilities { model.capabilities = capabilities }
        if let value = metadata.details?.parameter_size, LLMModel.parameterValue(value) != nil { model.parameters = value }
        if let count = metadata.model_info?.parameterCount, count.isFinite, count > 0 {
            model.reportedParameterCount = count
            if LLMModel.parameterValue(model.parameters) == nil {
                let divisor: Double = count >= 1e12 ? 1e12 : count >= 1e9 ? 1e9 : count >= 1e6 ? 1e6 : 1e3
                let unit = count >= 1e12 ? "T" : count >= 1e9 ? "B" : count >= 1e6 ? "M" : "K"
                model.parameters = String(format: "%.2f%@", locale: Locale(identifier: "en_US_POSIX"), count / divisor, unit)
            }
        }
        if let quantization = metadata.details?.quantization_level, !quantization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.quantization = quantization
        }
        return model
    }

    /// Décode `/api/tags` (internal : utilisé par les tests unitaires).
    static func decodeTags(_ data: Data) throws -> [LLMModel] {
        let response = try JSONDecoder().decode(OllamaListResponse.self, from: data)
        return response.models.map { m in
            LLMModel(
                id: m.name,
                name: m.name,
                parameters: m.details?.parameter_size,
                quantization: m.details?.quantization_level,
                sizeBytes: Int64(m.size),
                capabilities: m.details?.capabilities ?? [],
                modified: m.modified,
                source: m.name.hasSuffix(":cloud") ? .cloud : .ollama
            )
        }
    }
    
    // ── MODÈLES ACTIFS (en mémoire) ──
    
    func getLoadedModels() async -> [ModelInstance] {
        do {
            let url = baseURL.appendingPathComponent("api/ps")
            let (data, _) = try await URLSession.shared.data(from: url)
            return try Self.decodePS(data)
        } catch {
            print("⚠️ Ollama getLoadedModels error: \(error)")
            return []
        }
    }
    
    /// Décode `/api/ps` (internal : utilisé par les tests unitaires).
    static func decodePS(_ data: Data) throws -> [ModelInstance] {
        let response = try JSONDecoder().decode(OllamaPSResponse.self, from: data)
        return response.models.compactMap { m in
            ModelInstance(
                modelName: m.name,
                engine: .ollama,
                ram_MB: Double(m.size_vram) / (1024 * 1024),
                pid: nil,
                loadedAt: Date(),
                status: .active,
                sizeBytes: Int64(m.size),
                ttlMs: m.expiresAt.map { max(0, $0.timeIntervalSinceNow) * 1000 },
                processState: .unknown,
                quantization: m.details?.quantization_level,
                params: m.details?.parameter_size,
                contextLength: m.context_length
            )
        }
    }
    
    // ── ACTIONS ──
    
    func pullModel(name: String) async throws {
        let url = baseURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PullRequest(name: name))
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.pullFailed(String(data: data, encoding: .utf8) ?? L("Erreur inconnue"))
        }
    }
    
    func deleteModel(name: String) async throws {
        let url = baseURL.appendingPathComponent("api/delete")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeleteRequest(name: name))
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.deleteFailed
        }
    }
    
    func generate(prompt: String, model: String, system: String? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = GenerateRequest(
            model: model,
            prompt: prompt,
            system: system,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONDecoder().decode(GenerateResponse.self, from: data) else {
            throw OllamaError.responseParseFailed
        }
        return json.response
    }
    
    func chat(messages: [ChatMessage], model: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ChatRequest(model: model, messages: messages, stream: false)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw OllamaError.responseParseFailed
        }
        return json.message?.content ?? ""
    }

    /// Charge (force) un modèle via un prompt minimal — Ollama charge au premier appel.
    func loadModel(id: String) async throws {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": id,
            "prompt": "hi",
            "stream": false,
            "options": ["num_predict": 1]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }

    /// Décharge un modèle précis (`keep_alive: 0` — la méthode documentée
    /// par l'API HTTP d'Ollama ; le modèle part au prochain TTL).
    func unloadModel(id: String) async throws {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": id, "keep_alive": 0]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }

    /// Décharge TOUS les modèles Ollama chargés.
    func unloadAll() async throws {
        let loaded = await getLoadedModels()
        for inst in loaded {
            try? await unloadModel(id: inst.modelName)
        }
    }
    
    // ── TYPES DE RÉPONSE ──
    
    /// Décodage des dates Ollama : ISO8601 (0.35+ `modified_at`, `expires_at`),
    /// avec ou sans fractions de seconde.
    private enum OllamaDate {
        private static func make(_ fractional: Bool) -> ISO8601DateFormatter {
            let f = ISO8601DateFormatter()
            f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            return f
        }
        static func parse(_ s: String) -> Date? {
            let frac = make(true)
            let plain = make(false)
            return frac.date(from: s) ?? plain.date(from: s)
        }
    }
    
    private struct VersionResponse: Decodable { let version: String }
    private struct OllamaListResponse: Decodable { let models: [OllamaModel] }
    private struct ShowResponse: Decodable {
        let capabilities: [String]?
        let details: OllamaDetails?
        let model_info: ModelInfo?
        struct ModelInfo: Decodable {
            let parameterCount: Double?
            enum CodingKeys: String, CodingKey { case parameterCount = "general.parameter_count" }
        }
    }
    private struct OllamaDetails: Decodable {
        let parameter_size: String?
        let quantization_level: String?
        let capabilities: [String]?
    }
    private struct OllamaModel: Decodable {
        let name: String
        let size: Int
        let details: OllamaDetails?
        let modified: Date?
        
        private enum Keys: String, CodingKey {
            case name, size, details, modified
            case modifiedAt = "modified_at"
        }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name)
            size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
            details = try c.decodeIfPresent(OllamaDetails.self, forKey: .details)
            // Ollama 0.35+ : "modified_at" (ISO) — versions plus anciennes :
            // "modified" (timestamp unix OU chaîne ISO selon la version).
            if let s = try? c.decodeIfPresent(String.self, forKey: .modifiedAt),
               let d = OllamaDate.parse(s) {
                modified = d
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .modified),
                      let d = OllamaDate.parse(s) {
                modified = d
            } else if let unix = try? c.decodeIfPresent(Int.self, forKey: .modified) {
                modified = Date(timeIntervalSince1970: TimeInterval(unix))
            } else {
                modified = nil
            }
        }
    }
    private struct OllamaPSResponse: Decodable { let models: [PSModel] }
    private struct PSModel: Decodable {
        let name: String
        let size: Int
        let size_vram: Int
        let details: OllamaDetails?
        let expiresAt: Date?
        let context_length: Int?
        
        private enum Keys: String, CodingKey {
            case name, size, details, context_length
            case sizeVRAM = "size_vram"
            case expiresAt = "expires_at"
        }
        
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name)
            size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
            size_vram = try c.decodeIfPresent(Int.self, forKey: .sizeVRAM) ?? 0
            details = try c.decodeIfPresent(OllamaDetails.self, forKey: .details)
            context_length = try c.decodeIfPresent(Int.self, forKey: .context_length)
            if let s = try? c.decodeIfPresent(String.self, forKey: .expiresAt),
               let d = OllamaDate.parse(s) {
                expiresAt = d
            } else {
                expiresAt = nil
            }
        }
    }
    
    private struct PullRequest: Encodable { let name: String }
    private struct DeleteRequest: Encodable { let name: String }
    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let system: String?
        let stream: Bool
    }
    private struct GenerateResponse: Decodable { let response: String }
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }
    private struct ChatResponse: Decodable {
        let message: ChatMessage?
    }
}

// ── TYPES PARTAGÉS ──

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let role: String   // "user" | "assistant" | "system"
    let content: String

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
    }

    // The UI identity is local; Ollama and OpenAI-compatible APIs accept only role/content.
    private enum CodingKeys: String, CodingKey { case role, content }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        role = try values.decode(String.self, forKey: .role)
        content = try values.decode(String.self, forKey: .content)
    }
}

// ── ERREURS ──

enum OllamaError: LocalizedError {
    case pullFailed(String)
    case deleteFailed
    case responseParseFailed
    
    var errorDescription: String? {
        switch self {
        case .pullFailed(let msg): return L("Échec du téléchargement: %@", "\(msg)")
        case .deleteFailed: return L("Échec de la suppression du modèle")
        case .responseParseFailed: return L("Impossible d'analyser la réponse")
        }
    }
}
