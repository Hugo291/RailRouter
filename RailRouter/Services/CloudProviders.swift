import Foundation

/// Fournisseur cloud compatible OpenAI, branchable en un geste : clé collée dans l'app (ou variable d'environnement),
/// modèles exposés par l'endpoint sous `<id>/<modèle>`.
struct CloudProvider: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Racine de l'API, sans slash final (`…/v1`) ; vide pour Alibaba, dont l'hôte dépend de l'espace de travail.
    let baseURL: String
    let keyVariable: String
    /// Page où créer la clé.
    let keyPage: String
    let example: String

    var modelsURL: URL { URL(string: (id == "alibaba" ? GatewayAlibaba.baseURL() + "/v1" : baseURL) + "/models")! }
    /// OpenRouter liste ses modèles sans clé : on valide la clé sur `/auth/key`.
    var verifyURL: URL { id == "openrouter" ? URL(string: baseURL + "/auth/key")! : modelsURL }
    /// Anthropic n'accepte `Authorization: Bearer` que sur son point d'entrée de compatibilité OpenAI ; sa liste de modèles veut `x-api-key`.
    func authHeaders(key: String) -> [String: String] {
        var headers = ["Authorization": "Bearer " + key]
        if id == "anthropic" { headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01" }
        return headers
    }
}

enum CloudProviders {
    /// OpenRouter (modèles gratuits) et Alibaba (tarifs, test Codex) ont leur service dédié ; les autres passent par le routage générique.
    static let all: [CloudProvider] = [
        CloudProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", keyVariable: "OPENROUTER_API_KEY",
                      keyPage: "https://openrouter.ai/settings/keys", example: "nvidia/nemotron-3-super-120b-a12b:free"),
        CloudProvider(id: "alibaba", name: "Alibaba Cloud", baseURL: "", keyVariable: "DASHSCOPE_API_KEY",
                      keyPage: "https://bailian.console.alibabacloud.com/?tab=model#/api-key", example: "alibaba/qwen-plus"),
        CloudProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", keyVariable: "DEEPSEEK_API_KEY",
                      keyPage: "https://platform.deepseek.com/api_keys", example: "deepseek/deepseek-chat"),
        CloudProvider(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", keyVariable: "ANTHROPIC_API_KEY",
                      keyPage: "https://console.anthropic.com/settings/keys", example: "anthropic/claude-sonnet-4-5"),
        CloudProvider(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", keyVariable: "GEMINI_API_KEY",
                      keyPage: "https://aistudio.google.com/apikey", example: "gemini/gemini-2.5-flash"),
        CloudProvider(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", keyVariable: "MISTRAL_API_KEY",
                      keyPage: "https://console.mistral.ai/api-keys", example: "mistral/mistral-large-latest"),
        CloudProvider(id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1", keyVariable: "XAI_API_KEY",
                      keyPage: "https://console.x.ai", example: "xai/grok-4"),
        CloudProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", keyVariable: "GROQ_API_KEY",
                      keyPage: "https://console.groq.com/keys", example: "groq/llama-3.3-70b-versatile"),
        CloudProvider(id: "cerebras", name: "Cerebras", baseURL: "https://api.cerebras.ai/v1", keyVariable: "CEREBRAS_API_KEY",
                      keyPage: "https://cloud.cerebras.ai", example: "cerebras/llama-3.3-70b"),
        CloudProvider(id: "moonshot", name: "Moonshot (Kimi)", baseURL: "https://api.moonshot.ai/v1", keyVariable: "MOONSHOT_API_KEY",
                      keyPage: "https://platform.moonshot.ai/console/api-keys", example: "moonshot/kimi-k2-0905-preview"),
        CloudProvider(id: "zai", name: "Z.ai (GLM)", baseURL: "https://api.z.ai/api/paas/v4", keyVariable: "ZAI_API_KEY",
                      keyPage: "https://z.ai/manage-apikey/apikey-list", example: "zai/glm-4.6"),
        CloudProvider(id: "nvidia", name: "NVIDIA NIM", baseURL: "https://integrate.api.nvidia.com/v1", keyVariable: "NVIDIA_API_KEY",
                      keyPage: "https://build.nvidia.com/settings/api-keys", example: "nvidia/meta/llama-3.3-70b-instruct")
    ]
    static let generic = all.filter { $0.id != "openrouter" && $0.id != "alibaba" }

    static func provider(id: String) -> CloudProvider? { all.first { $0.id == id } }
    static func generic(id: String) -> CloudProvider? { generic.first { $0.id == id } }

    /// `deepseek/deepseek-chat` → (DeepSeek, `deepseek-chat`) ; nil pour tout autre identifiant.
    static func route(model: String) -> (provider: CloudProvider, model: String)? {
        guard let slash = model.firstIndex(of: "/"), model.index(after: slash) < model.endIndex,
              let provider = generic(id: String(model[..<slash])) else { return nil }
        return (provider, String(model[model.index(after: slash)...]))
    }

    // MARK: Clés

    /// Fichier partagé avec le service de l'endpoint (processus séparé, sans l'environnement de l'app) ; lisible par l'utilisateur seul.
    static var keyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RailRouter/provider-keys.json")
    }

    static func storedKeys(file: URL = keyFile) -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }

    /// Variable d'environnement d'abord, puis clé enregistrée par l'app. Jamais journalisée.
    static func apiKey(for id: String, environment: [String: String] = ProcessInfo.processInfo.environment, file: URL = keyFile) -> String? {
        let candidates = [provider(id: id).flatMap { environment[$0.keyVariable] }, storedKeys(file: file)[id]]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    static func save(key: String, for id: String, file: URL = keyFile) throws {
        var keys = storedKeys(file: file)
        keys[id] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(keys, to: file)
    }

    static func remove(id: String, file: URL = keyFile) throws {
        var keys = storedKeys(file: file)
        guard keys.removeValue(forKey: id) != nil else { return }
        try write(keys, to: file)
    }

    private static func write(_ keys: [String: String], to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: keys, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Réseau

    enum Check: Equatable {
        case valid
        case rejected
        /// Réponse HTTP inattendue (point d'entrée de liste absent…) : la clé n'est pas démentie.
        case unverified(Int)
        case unreachable(String)
    }

    /// Une requête de lecture avec la clé fournie : 2xx = clé valable, 401/403 = refusée.
    static func verify(_ provider: CloudProvider, key: String, session: URLSession = .shared) async -> Check {
        var request = URLRequest(url: provider.verifyURL)
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        for (name, value) in provider.authHeaders(key: key) { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (_, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return .valid
            case 401, 403: return .rejected
            case let status: return .unverified(status)
            }
        } catch { return .unreachable(error.localizedDescription) }
    }

    /// `data` de `GET <base>/models` ; vide au moindre échec (id, created, owned_by seulement).
    static func entries(_ provider: CloudProvider, key: String, session: URLSession = .shared) async -> [[String: Any]] {
        var request = URLRequest(url: provider.modelsURL)
        request.timeoutInterval = 4
        request.httpShouldHandleCookies = false
        for (name, value) in provider.authHeaders(key: key) { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request, delegate: GatewayNoRedirect()),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (json["data"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String)?.isEmpty == false }
    }

    /// Catalogue de chaque fournisseur générique connecté, au format `{"data":[…]}` de l'endpoint.
    static func catalogs(session: URLSession, environment: [String: String] = ProcessInfo.processInfo.environment,
                         keyFile: URL = keyFile) async -> [String: [String: Any]] {
        await withTaskGroup(of: (String, [[String: Any]]).self) { group in
            for provider in generic {
                guard let key = apiKey(for: provider.id, environment: environment, file: keyFile) else { continue }
                group.addTask { (provider.id, await entries(provider, key: key, session: session)) }
            }
            var result: [String: [String: Any]] = [:]
            for await (id, entries) in group where !entries.isEmpty {
                result[id] = ["data": entries.map { ["id": $0["id"] as Any, "created": $0["created"] as Any, "owned_by": id] }]
            }
            return result
        }
    }

    /// Modèles de la bibliothèque pour un fournisseur : capacités et taille déduites du nom (aucun de ces services ne les publie).
    static func models(for provider: CloudProvider, entries: [[String: Any]]) -> [LLMModel] {
        entries.compactMap { item in
            guard let raw = item["id"] as? String else { return nil }
            // Gemini liste `models/gemini-…` : le préfixe reste dans l'identifiant (accepté par Google), pas dans le nom affiché.
            return LLMModel(id: provider.id + "/" + raw, name: raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw,
                            parameters: OpenRouterService.parameterLabel(id: raw, description: nil),
                            quantization: nil, sizeBytes: 0, capabilities: AlibabaService.capabilities(id: raw),
                            modified: (item["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                            source: .provider)
        }
    }

    static func models(session: URLSession = .shared) async -> [LLMModel] {
        let catalogs = await catalogs(session: session)
        return generic.flatMap { provider in
            models(for: provider, entries: catalogs[provider.id]?["data"] as? [[String: Any]] ?? [])
        }
    }
}
