import Foundation

final class CloudProvidersTests: XCTestCase {
    override func runAll() {
        // Préfixe `<fournisseur>/` : le reste (même avec des « / ») va tel quel en amont.
        let deepseek = CloudProviders.route(model: "deepseek/deepseek-chat")
        XCTAssertEqual(deepseek?.provider.id, "deepseek")
        XCTAssertEqual(deepseek?.model, "deepseek-chat")
        XCTAssertEqual(CloudProviders.route(model: "nvidia/meta/llama-3.3-70b-instruct")?.model, "meta/llama-3.3-70b-instruct")
        for model in ["deepseek", "deepseek/", "alibaba/qwen-plus", "openrouter/free", "qwen3:8b", "inconnu/x"] {
            XCTAssertNil(CloudProviders.route(model: model))
        }

        // Routage de l'endpoint : URL de base du fournisseur + chemin sans son « /v1 ».
        let catalog = GatewayCatalog()
        func url(_ model: String, _ path: String = "/v1/chat/completions") -> String? {
            try? UnifiedGateway.route(path: path, model: model, catalog: catalog).url.absoluteString
        }
        XCTAssertEqual(url("deepseek/deepseek-chat"), "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(url("gemini/gemini-2.5-flash"), "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(url("zai/glm-4.6", "/v1/embeddings"), "https://api.z.ai/api/paas/v4/embeddings")
        XCTAssertEqual(try? UnifiedGateway.route(path: "/v1/chat/completions", model: "groq/llama-3.3-70b", catalog: catalog).model, "llama-3.3-70b")
        // Les ids OpenRouter gratuits commencent aussi par un éditeur : ils restent chez OpenRouter.
        XCTAssertEqual(try? UnifiedGateway.route(path: "/v1/chat/completions", model: "deepseek/deepseek-r1:free", catalog: catalog).source, "openrouter")
        XCTAssertEqual(UnifiedGateway.upstreamHeaders(["Accept": "a", "X-Codex-Secret": "s"], source: "groq"), ["Accept": "a"])

        // Clés : variable d'environnement d'abord, fichier ensuite, 0600, suppression.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("railrouter-keys-\(UUID().uuidString)/provider-keys.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertNil(CloudProviders.apiKey(for: "groq", environment: [:], file: file))
        try? CloudProviders.save(key: "  gsk_file \n", for: "groq", file: file)
        XCTAssertEqual(CloudProviders.apiKey(for: "groq", environment: [:], file: file), "gsk_file")
        XCTAssertEqual(CloudProviders.apiKey(for: "groq", environment: ["GROQ_API_KEY": " gsk_env "], file: file), "gsk_env")
        XCTAssertEqual(CloudProviders.apiKey(for: "groq", environment: ["GROQ_API_KEY": "  "], file: file), "gsk_file")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try? CloudProviders.save(key: "k2", for: "mistral", file: file)
        try? CloudProviders.remove(id: "groq", file: file)
        XCTAssertNil(CloudProviders.apiKey(for: "groq", environment: [:], file: file))
        XCTAssertEqual(CloudProviders.apiKey(for: "mistral", environment: [:], file: file), "k2")

        // Catalogue : identifiants préfixés, modèle de bibliothèque rattaché au bon fournisseur.
        let clouds = GatewayCatalog(clouds: ["groq": ["data": [["id": "llama-3.3-70b-versatile"]]]])
        XCTAssertEqual(clouds.models.first?["id"] as? String, "groq/llama-3.3-70b-versatile")
        let groq = CloudProviders.generic(id: "groq")!
        let models = CloudProviders.models(for: groq, entries: [["id": "llama-3.3-70b-versatile", "created": NSNumber(value: 1_700_000_000)], ["x": 1]])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.id, "groq/llama-3.3-70b-versatile")
        XCTAssertEqual(models.first?.name, "llama-3.3-70b-versatile")
        XCTAssertEqual(models.first?.source, .provider)
        XCTAssertEqual(models.first?.librarySource, "Groq")
        XCTAssertEqual(models.first?.isCloudHosted, true)
        XCTAssertEqual(models.first?.parameters, "70B")
    }
}
