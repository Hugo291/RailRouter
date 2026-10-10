import Foundation

/// Résultat du test « si je mets ce modèle dans Codex, ça marche ? ».
struct CodexVerdict: Codable, Equatable {
    var compatible: Bool
    /// Message d'erreur d'Alibaba quand le modèle est refusé.
    var reason: String?
    var date: Date
}

/// Envoie à un modèle Alibaba la requête que Codex lui enverrait (Responses, flux, un outil, raisonnement « medium »,
/// comme le déclare le catalogue de Codex), sans lancer Codex. Alibaba n'annonce pas quels modèles gèrent `/responses` :
/// `qwen-max` y répond 500, `qwen-plus` échoue dès qu'on demande du raisonnement, `qwen3-*` n'y existe pas.
enum CodexProbe {
    private static let body: [String: Any] = [
        "instructions": "Reply ok.",
        "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "ok"]]]],
        "tools": [["type": "function", "name": "noop", "description": "noop", "parameters": ["type": "object", "properties": [String: Any]()]]],
        "reasoning": ["effort": "medium"],
        "stream": true, "store": false, "max_output_tokens": 32
    ]

    /// nil : essai non concluant (pas de clé, réseau, quota) — ni oui ni non.
    static func run(_ id: String, session: URLSession = .shared) async -> CodexVerdict? {
        guard id.hasPrefix("alibaba/"), let key = GatewayAlibaba.apiKey(),
              let url = URL(string: GatewayAlibaba.baseURL() + "/v1/responses") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        var payload = body
        payload["model"] = String(id.dropFirst("alibaba/".count))
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, response) = try? await session.data(for: request, delegate: GatewayNoRedirect()),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        return verdict(status: status, body: String(decoding: data, as: UTF8.self))
    }

    /// Compatible : HTTP 200 et le flux se termine (`response.completed`, ou `response.incomplete` si le plafond de
    /// 32 tokens est atteint) sans `response.failed`. Alibaba renvoie aussi les échecs en 200 dans le flux.
    static func verdict(status: Int, body: String, now: Date = .now) -> CodexVerdict? {
        if [401, 403, 408, 429, 502, 503, 504].contains(status) { return nil }
        let failed = status != 200 || body.contains("response.failed")
        if !failed {
            guard body.contains("response.completed") || body.contains("response.incomplete") else { return nil }
            return CodexVerdict(compatible: true, reason: nil, date: now)
        }
        return CodexVerdict(compatible: false, reason: message(in: body) ?? "HTTP \(status)", date: now)
    }

    /// Premier `error.message` du corps : JSON simple, ou événements SSE (`data:{"response":{"error":…}}`).
    static func message(in body: String) -> String? {
        let lines = body.split(separator: "\n").map { $0.hasPrefix("data:") ? $0.dropFirst(5) : $0 }
        for text in [Substring(body)] + lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            let error = json["error"] as? [String: Any] ?? (json["response"] as? [String: Any])?["error"] as? [String: Any]
            if let message = error?["message"] as? String { return message }
        }
        return nil
    }
}
