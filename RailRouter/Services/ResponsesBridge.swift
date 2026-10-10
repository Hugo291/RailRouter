import Foundation

/// Pont Responses → chat/completions pour les fournisseurs cloud qui n'ont que cette dernière (Gemini, DeepSeek…) :
/// la requête de Codex est traduite, puis le flux chat est rejoué sous forme d'événements Responses.
enum GatewayResponsesBridge {
    /// `extra_content` rendu par le fournisseur avec un appel d'outil (signature de réflexion de Gemini) :
    /// il doit lui revenir au tour suivant, et Codex ne conserve pas ce champ.
    // ponytail: mémoire du processus, perdue au redémarrage de l'endpoint ; le repli est la signature neutre de Google.
    final class Extras: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        private var order: [String] = []
        func get(_ id: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[id] }
        func put(_ id: String, _ value: Any) {
            lock.lock(); defer { lock.unlock() }
            if values.updateValue(value, forKey: id) == nil { order.append(id) }
            if order.count > 2048 { values[order.removeFirst()] = nil }
        }
    }
    static let extras = Extras()
    /// Valeur documentée par Google pour un appel dont la signature d'origine est perdue.
    static let neutralSignature: [String: Any] = ["google": ["thought_signature": "skip_thought_signature_validator"]]
    /// Les outils d'un espace de noms (`mcp__serveur` + `outil`) deviennent des fonctions à plat.
    static let separator = "__"

    // MARK: Requête

    static func chatBody(_ object: [String: Any], provider: CloudProvider, model: String, extras: Extras = extras) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if let instructions = object["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        var items = try UnifiedGateway.localResponsesBody(object, mlx: false)["input"] as? [[String: Any]] ?? []
        if let prompt = object["input"] as? String { items = [["type": "message", "role": "user", "content": prompt]] }
        for item in items {
            switch item["type"] as? String ?? "message" {
            case "message":
                var role = item["role"] as? String ?? "user"
                if role == "developer" || role == "system" {
                    // Hors tête de conversation, un message système fait échouer le gabarit de nombreux modèles ouverts.
                    role = messages.allSatisfy { $0["role"] as? String == "system" } ? "system" : "user"
                }
                messages.append(["role": role, "content": content(item["content"], images: role == "user")])
            case "function_call":
                let id = item["call_id"] as? String ?? ""
                var call: [String: Any] = ["id": id, "type": "function",
                                           "function": ["name": flatName(item), "arguments": item["arguments"] as? String ?? "{}"]]
                call["extra_content"] = extras.get(id)
                // Texte et appels d'une même réponse (ou appels parallèles) : un seul message assistant.
                if messages.last?["role"] as? String == "assistant" {
                    messages[messages.count - 1]["tool_calls"] = (messages[messages.count - 1]["tool_calls"] as? [[String: Any]] ?? []) + [call]
                } else {
                    messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [call]])
                }
            case "function_call_output":
                // ponytail: texte seul, l'image rendue par `view_image` est perdue (chat/completions n'en accepte pas ici).
                messages.append(["role": "tool", "tool_call_id": item["call_id"] as? String ?? "",
                                 "content": content(item["output"], images: false)])
            default: break // raisonnement : jamais renvoyé à un autre fournisseur
            }
        }
        if provider.id == "gemini" {
            for index in messages.indices {
                guard var calls = messages[index]["tool_calls"] as? [[String: Any]], let first = calls.first, first["extra_content"] == nil else { continue }
                calls[0]["extra_content"] = neutralSignature
                messages[index]["tool_calls"] = calls
            }
        }

        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        // Mistral refuse les champs qu'il ne connaît pas et donne l'usage d'office.
        if provider.id != "mistral" { body["stream_options"] = ["include_usage": true] }
        let tools = (object["tools"] as? [[String: Any]] ?? []).flatMap { functions($0) }
        if !tools.isEmpty {
            body["tools"] = tools
            if let choice = object["tool_choice"] as? String, choice != "auto" { body["tool_choice"] = choice }
        }
        if let limit = object["max_output_tokens"] as? NSNumber { body["max_tokens"] = limit }
        for key in ["temperature", "top_p"] { body[key] = object[key] as? NSNumber }
        if let format = (object["text"] as? [String: Any])?["format"] as? [String: Any], format["type"] as? String == "json_schema" {
            body["response_format"] = ["type": "json_schema", "json_schema": [
                "name": format["name"] ?? "output", "schema": format["schema"] ?? [String: Any](), "strict": format["strict"] ?? false]]
        }
        return body
    }

    /// `input_text` / `output_text` → texte ; `input_image` → `image_url`. Sans image, une simple chaîne.
    static func content(_ value: Any?, images: Bool) -> Any {
        if let text = value as? String { return text }
        let parts: [[String: Any]] = (value as? [[String: Any]] ?? []).compactMap { part in
            if let text = part["text"] as? String { return ["type": "text", "text": text] }
            if images, part["type"] as? String == "input_image", let url = part["image_url"] as? String {
                return ["type": "image_url", "image_url": ["url": url]]
            }
            return nil
        }
        return parts.contains { $0["type"] as? String == "image_url" } ? parts
            : parts.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    static func flatName(_ item: [String: Any]) -> String {
        let name = item["name"] as? String ?? ""
        return (item["namespace"] as? String).map { $0 + separator + name } ?? name
    }

    /// Outils Responses → fonctions chat. Les outils hébergés par OpenAI (`web_search`, `tool_search`…) n'ont pas d'équivalent.
    static func functions(_ tool: [String: Any], namespace: String? = nil) -> [[String: Any]] {
        guard let name = tool["name"] as? String else { return [] }
        var function: [String: Any] = ["name": namespace.map { $0 + separator + name } ?? name]
        function["description"] = tool["description"]
        switch tool["type"] as? String {
        case "function": function["parameters"] = tool["parameters"] ?? ["type": "object", "properties": [String: Any]()]
        case "custom": // texte libre (apply_patch) : un seul argument `input`, forme que Codex accepte en retour
            function["parameters"] = ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"]]
        case "namespace": return (tool["tools"] as? [[String: Any]] ?? []).flatMap { functions($0, namespace: name) }
        default: return []
        }
        return [["type": "function", "function": function]]
    }

    /// Message d'un corps d'erreur amont : `{"error":{"message":…}}`, sa variante en tableau (Gemini) ou le texte brut.
    static func errorMessage(_ data: Data) -> String {
        var json = try? JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] { json = list.first }
        let object = json as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String ?? object?["error"] as? String ?? object?["message"] as? String
        return String((message ?? String(decoding: data, as: UTF8.self)).prefix(2000))
    }

    // MARK: Réponse

    /// Rejoue un flux chat/completions sous forme d'événements Responses (`event:` + `data:`), dans l'ordre attendu par Codex.
    struct Stream {
        private struct Call { var id = "", name = "", arguments = ""; var extra: Any? }
        private let id = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        private let model: String
        private let extras: Extras
        private var namespaces: [String: (namespace: String, name: String)] = [:]
        private var sequence = 0
        private var started = false
        private var finished = false
        private var reasoning: String?
        private var text: String?
        private var calls: [Int: Call] = [:]
        private var output: [[String: Any]] = []
        private var usage: [String: Any]?
        private var ended = false
        private(set) var failure: String?

        init(model: String, tools: Any?, extras: Extras = GatewayResponsesBridge.extras) {
            self.model = model
            self.extras = extras
            for tool in tools as? [[String: Any]] ?? [] where tool["type"] as? String == "namespace" {
                guard let namespace = tool["name"] as? String else { continue }
                for inner in tool["tools"] as? [[String: Any]] ?? [] {
                    guard let name = inner["name"] as? String else { continue }
                    namespaces[namespace + separator + name] = (namespace, name)
                }
            }
        }

        /// Une ligne du flux amont ; seules les lignes `data:` portent un fragment.
        mutating func ingest(line: Data) -> [Data] {
            var line = line
            if line.last == 13 { line.removeLast() }
            if line == Data("data: [DONE]".utf8) { ended = true }
            guard line.starts(with: Data("data:".utf8)),
                  let chunk = try? JSONSerialization.jsonObject(with: line.dropFirst(5)) as? [String: Any] else { return [] }
            return ingest(chunk)
        }

        mutating func ingest(_ chunk: [String: Any]) -> [Data] {
            var events = start()
            if let error = chunk["error"] {
                failure = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "Upstream error"
                return events
            }
            if let usage = chunk["usage"] as? [String: Any] { self.usage = usage }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return events }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let piece = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !piece.isEmpty, text == nil {
                if reasoning == nil {
                    reasoning = ""
                    events.append(event("response.output_item.added", ["output_index": output.count, "item": reasoningItem]))
                    events.append(event("response.reasoning_summary_part.added", ["item_id": itemID("rs"), "output_index": output.count,
                                                                                  "summary_index": 0, "part": ["type": "summary_text", "text": ""]]))
                }
                reasoning? += piece
                events.append(event("response.reasoning_summary_text.delta", ["item_id": itemID("rs"), "output_index": output.count,
                                                                              "summary_index": 0, "delta": piece]))
            }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                if text == nil {
                    events += closeReasoning()
                    text = ""
                    events.append(event("response.output_item.added", ["output_index": output.count, "item": messageItem(status: "in_progress")]))
                    events.append(event("response.content_part.added", ["item_id": itemID("msg"), "output_index": output.count, "content_index": 0,
                                                                        "part": ["type": "output_text", "text": "", "annotations": [Any]()]]))
                }
                text? += piece
                events.append(event("response.output_text.delta", ["item_id": itemID("msg"), "output_index": output.count,
                                                                   "content_index": 0, "delta": piece]))
            }
            for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let function = fragment["function"] as? [String: Any] ?? [:]
                let id = fragment["id"] as? String ?? ""
                let name = function["name"] as? String ?? ""
                let index = slot(fragment["index"] as? Int, id: id, named: !name.isEmpty)
                var call = calls[index] ?? Call()
                if call.id.isEmpty { call.id = id }
                if call.name.isEmpty { call.name = name } // le nom arrive entier ; certains fournisseurs le répètent
                if let piece = function["arguments"] as? String { call.arguments += piece }
                else if let value = function["arguments"], !(value is NSNull), let data = try? JSONSerialization.data(withJSONObject: value) {
                    call.arguments = String(decoding: data, as: UTF8.self)
                }
                if let extra = fragment["extra_content"], !(extra is NSNull) { call.extra = extra }
                calls[index] = call
            }
            if choice["finish_reason"] is String { ended = true; events += closeItems() }
            return events
        }

        /// Fin du flux amont : `response.completed` (ou `response.failed`), avec l'usage arrivé après le dernier fragment.
        mutating func finish() -> [Data] {
            guard !finished else { return [] }
            finished = true
            // Amont coupé sans `finish_reason` ni `[DONE]` (modèle déchargé, connexion perdue) : un échec, pas une réponse tronquée.
            if failure == nil, !ended { failure = "Upstream stream ended before completion" }
            var events = start() + closeItems()
            if let failure {
                var failed = envelope("failed")
                failed["error"] = ["code": "upstream_error", "message": failure]
                events.append(event("response.failed", ["response": failed]))
            } else { events.append(event("response.completed", ["response": response])) }
            return events
        }

        /// Objet Responses final : charge utile de `response.completed`, et réponse entière d'un client sans flux.
        var response: [String: Any] {
            var value = envelope("completed")
            value["output"] = output
            if let usage {
                func count(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
                let input = count(usage["prompt_tokens"]), produced = count(usage["completion_tokens"])
                value["usage"] = [
                    "input_tokens": input, "output_tokens": produced,
                    "total_tokens": usage["total_tokens"] is NSNumber ? count(usage["total_tokens"]) : input + produced,
                    "input_tokens_details": ["cached_tokens": count((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])],
                    "output_tokens_details": ["reasoning_tokens": count((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"])]]
            }
            return value
        }

        /// Gemini omet `index`, d'autres le laissent à 0 pour chaque appel parallèle : l'identifiant départage.
        private func slot(_ index: Int?, id: String, named: Bool) -> Int {
            if !id.isEmpty, let known = calls.first(where: { $0.value.id == id })?.key { return known }
            if let index, calls[index] == nil || id.isEmpty { return index }
            if id.isEmpty, !named, let last = calls.keys.max() { return last }
            return (calls.keys.max() ?? -1) + 1
        }

        private mutating func start() -> [Data] {
            guard !started else { return [] }
            started = true
            return [event("response.created", ["response": envelope("in_progress")])]
        }

        private mutating func closeReasoning() -> [Data] {
            guard reasoning != nil else { return [] }
            let item = reasoningItem
            reasoning = nil
            defer { output.append(item) }
            return [event("response.output_item.done", ["output_index": output.count, "item": item])]
        }

        private mutating func closeItems() -> [Data] {
            var events = closeReasoning()
            if let text {
                let item = messageItem(status: "completed")
                let part: [String: Any] = ["type": "output_text", "text": text, "annotations": [Any]()]
                let position: [String: Any] = ["item_id": itemID("msg"), "output_index": output.count, "content_index": 0]
                events.append(event("response.output_text.done", position.merging(["text": text]) { $1 }))
                events.append(event("response.content_part.done", position.merging(["part": part]) { $1 }))
                events.append(event("response.output_item.done", ["output_index": output.count, "item": item]))
                output.append(item)
                self.text = nil
            }
            for index in calls.keys.sorted() {
                let call = calls[index]!
                let callID = call.id.isEmpty ? "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : call.id
                if let extra = call.extra { extras.put(callID, extra) }
                var item: [String: Any] = ["type": "function_call", "id": itemID("fc"), "call_id": callID, "status": "completed",
                                           "name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]
                if let scoped = namespaces[call.name] { item["name"] = scoped.name; item["namespace"] = scoped.namespace }
                events.append(event("response.output_item.added", ["output_index": output.count, "item": item]))
                events.append(event("response.output_item.done", ["output_index": output.count, "item": item]))
                output.append(item)
            }
            calls.removeAll()
            return events
        }

        private func itemID(_ prefix: String) -> String { "\(prefix)_\(id.dropFirst(5))_\(output.count)" }
        private func envelope(_ status: String) -> [String: Any] {
            ["id": id, "object": "response", "status": status, "model": model, "output": [Any]()]
        }
        private var reasoningItem: [String: Any] {
            ["id": itemID("rs"), "type": "reasoning", "summary": (reasoning ?? "").isEmpty ? [] : [["type": "summary_text", "text": reasoning ?? ""]]]
        }
        private func messageItem(status: String) -> [String: Any] {
            ["id": itemID("msg"), "type": "message", "role": "assistant", "status": status,
             "content": (text ?? "").isEmpty ? [] : [["type": "output_text", "text": text ?? "", "annotations": [Any]()]]]
        }

        private mutating func event(_ type: String, _ fields: [String: Any]) -> Data {
            var payload = fields
            payload["type"] = type
            payload["sequence_number"] = sequence
            sequence += 1
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return Data("event: \(type)\ndata: ".utf8) + json + Data("\n\n".utf8)
        }
    }
}
