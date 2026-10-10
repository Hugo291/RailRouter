import Foundation

final class ResponsesBridgeTests: XCTestCase {
    /// Événements émis, décodés : (type, charge utile).
    private func decode(_ frames: [Data]) -> [(type: String, payload: [String: Any])] {
        frames.compactMap { frame in
            let lines = String(decoding: frame, as: UTF8.self).split(separator: "\n")
            guard lines.count == 2, lines[0].hasPrefix("event: "), lines[1].hasPrefix("data: "),
                  let payload = try? JSONSerialization.jsonObject(with: Data(lines[1].dropFirst(6).utf8)) as? [String: Any] else { return nil }
            return (String(lines[0].dropFirst(7)), payload)
        }
    }
    private func chunk(_ json: String) -> Data { Data("data: \(json)".utf8) }

    override func runAll() {
        let deepseek = CloudProviders.generic(id: "deepseek")!, gemini = CloudProviders.generic(id: "gemini")!
        let extras = GatewayResponsesBridge.Extras()
        extras.put("call_signed", ["google": ["thought_signature": "sig-A"]])

        // ── Requête : historique Codex → messages chat ──
        let request: [String: Any] = [
            "model": "gemini/models/gemini-x", "instructions": "You are Codex.", "stream": true, "tool_choice": "auto",
            "input": [
                ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "rules"], ["type": "input_text", "text": "more"]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "look"], ["type": "input_image", "image_url": "data:image/png;base64,AAAA"]]],
                ["type": "reasoning", "summary": [["type": "summary_text", "text": "thinking"]]],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "I run it."]]],
                ["type": "function_call", "call_id": "call_signed", "name": "exec_command", "arguments": "{\"cmd\":\"ls\"}"],
                ["type": "function_call", "call_id": "call_2", "name": "js", "namespace": "mcp__cua", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "call_signed", "output": "a.txt"],
                ["type": "function_call_output", "call_id": "call_2", "output": [["type": "input_text", "text": "done"]]],
                ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "late note"]]],
                ["type": "custom_tool_call", "call_id": "call_3", "name": "apply_patch", "input": "*** Begin Patch"],
                ["type": "custom_tool_call_output", "call_id": "call_3", "output": "ok"]
            ],
            "tools": [
                ["type": "function", "name": "exec_command", "description": "Runs", "strict": false, "parameters": ["type": "object", "properties": ["cmd": ["type": "string"]]]],
                ["type": "namespace", "name": "mcp__cua", "description": "UI", "tools": [["type": "function", "name": "js", "parameters": ["type": "object"]]]],
                ["type": "custom", "name": "apply_patch", "description": "Patch"],
                ["type": "web_search", "external_web_access": true],
                ["type": "tool_search", "execution": "client", "description": "x", "parameters": ["type": "object"]]
            ],
            "text": ["format": ["type": "json_schema", "name": "out", "schema": ["type": "object"], "strict": true]]
        ]
        let body = try! GatewayResponsesBridge.chatBody(request, provider: gemini, model: "models/gemini-x", extras: extras)
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "system", "user", "assistant", "tool", "tool", "user", "assistant", "tool"])
        XCTAssertEqual(messages[0]["content"] as? String, "You are Codex.")
        XCTAssertEqual(messages[1]["content"] as? String, "rules\n\nmore")
        let userParts = messages[2]["content"] as? [[String: Any]]
        XCTAssertEqual(userParts?.map { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertEqual((userParts?[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,AAAA")
        // Texte et appels parallèles d'une même réponse : un seul message assistant, le raisonnement n'est pas renvoyé.
        XCTAssertEqual(messages[3]["content"] as? String, "I run it.")
        let calls = messages[3]["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(calls.map { ($0["function"] as? [String: Any])?["name"] as? String }, ["exec_command", "mcp__cua__js"])
        XCTAssertEqual(((calls[0]["extra_content"] as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String, "sig-A")
        XCTAssertNil(calls[1]["extra_content"])
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "call_signed")
        XCTAssertEqual(messages[5]["content"] as? String, "done")
        XCTAssertEqual(messages[6]["content"] as? String, "late note")
        // Appel d'outil à texte libre : fonction à un argument ; sans signature connue, Gemini reçoit la valeur neutre.
        let patch = (messages[7]["tool_calls"] as! [[String: Any]])[0]
        XCTAssertTrue(messages[7]["content"] is NSNull)
        XCTAssertEqual((patch["function"] as? [String: Any])?["arguments"] as? String, "{\"input\":\"*** Begin Patch\"}")
        XCTAssertEqual(((patch["extra_content"] as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String, "skip_thought_signature_validator")
        let tools = body["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.map { ($0["function"] as? [String: Any])?["name"] as? String }, ["exec_command", "mcp__cua__js", "apply_patch"])
        XCTAssertTrue(tools.allSatisfy { $0["type"] as? String == "function" && ($0["function"] as? [String: Any])?["strict"] == nil })
        XCTAssertEqual(body["model"] as? String, "models/gemini-x")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["tool_choice"])
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual(((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["name"] as? String, "out")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))

        // Autre fournisseur : pas de signature inventée ; Mistral sans `stream_options` ; entrée en simple chaîne.
        let plain = try! GatewayResponsesBridge.chatBody(request, provider: deepseek, model: "deepseek-chat", extras: GatewayResponsesBridge.Extras())
        XCTAssertTrue((plain["messages"] as! [[String: Any]]).allSatisfy { ($0["tool_calls"] as? [[String: Any]] ?? []).allSatisfy { $0["extra_content"] == nil } })
        let short = try! GatewayResponsesBridge.chatBody(["input": "hi", "max_output_tokens": 50, "tool_choice": "required"],
                                                         provider: CloudProviders.generic(id: "mistral")!, model: "mistral-large")
        XCTAssertNil(short["stream_options"])
        XCTAssertNil(short["tools"])
        XCTAssertNil(short["tool_choice"])
        XCTAssertEqual(short["max_tokens"] as? Int, 50)
        XCTAssertEqual((short["messages"] as? [[String: Any]])?.first?["content"] as? String, "hi")

        // ── Flux : texte en deux fragments, usage après le dernier fragment ──
        var text = GatewayResponsesBridge.Stream(model: "deepseek/deepseek-chat", tools: nil, extras: extras)
        var frames = text.ingest(line: chunk(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}"#))
        frames += text.ingest(line: Data(": keep-alive".utf8))
        frames += text.ingest(line: chunk(#"{"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"stop"}]}"#) + Data("\r".utf8))
        frames += text.ingest(line: chunk(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":4}}}"#))
        frames += text.ingest(line: chunk("[DONE]"))
        frames += text.finish()
        XCTAssertTrue(text.finish().isEmpty)
        let events = decode(frames)
        XCTAssertEqual(events.map(\.type), ["response.created", "response.output_item.added", "response.content_part.added",
                                            "response.output_text.delta", "response.output_text.delta", "response.output_text.done",
                                            "response.content_part.done", "response.output_item.done", "response.completed"])
        XCTAssertEqual(events.map { $0.payload["sequence_number"] as? Int }, Array(0..<9))
        XCTAssertEqual(events[3].payload["delta"] as? String, "Hel")
        let done = events[7].payload["item"] as? [String: Any]
        XCTAssertEqual(done?["type"] as? String, "message")
        XCTAssertEqual(((done?["content"] as? [[String: Any]])?.first)?["text"] as? String, "Hello")
        XCTAssertEqual(events[1].payload["output_index"] as? Int, 0)
        XCTAssertEqual((events[1].payload["item"] as? [String: Any])?["id"] as? String, done?["id"] as? String)
        let completed = events[8].payload["response"] as? [String: Any]
        XCTAssertEqual(completed?["status"] as? String, "completed")
        XCTAssertEqual(completed?["model"] as? String, "deepseek/deepseek-chat")
        XCTAssertEqual((completed?["id"] as? String)?.hasPrefix("resp_"), true)
        XCTAssertEqual((completed?["output"] as? [[String: Any]])?.count, 1)
        let usage = completed?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["input_tokens"] as? Int, 12)
        XCTAssertEqual(usage?["output_tokens"] as? Int, 7)
        XCTAssertEqual(usage?["total_tokens"] as? Int, 19)
        XCTAssertEqual((usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int, 4)
        XCTAssertEqual((usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int, 0)

        // ── Appels d'outils façon OpenAI : arguments fragmentés, raisonnement avant, deux appels indexés ──
        var indexed = GatewayResponsesBridge.Stream(model: "m", tools: nil, extras: extras)
        frames = indexed.ingest(line: chunk(#"{"choices":[{"delta":{"reasoning_content":"Let me "}}]}"#))
        frames += indexed.ingest(line: chunk(#"{"choices":[{"delta":{"reasoning_content":"check."}}]}"#))
        frames += indexed.ingest(line: chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"exec_command","arguments":"{\"cmd\":"}}]}}]}"#))
        frames += indexed.ingest(line: chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}},{"index":1,"id":"call_b","function":{"name":"write_stdin","arguments":""}}]}}]}"#))
        frames += indexed.ingest(line: chunk(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        frames += indexed.finish()
        let toolEvents = decode(frames)
        XCTAssertEqual(toolEvents.map(\.type), ["response.created", "response.output_item.added", "response.reasoning_summary_part.added",
                                                "response.reasoning_summary_text.delta", "response.reasoning_summary_text.delta",
                                                "response.output_item.done", "response.output_item.added", "response.output_item.done",
                                                "response.output_item.added", "response.output_item.done", "response.completed"])
        let thought = toolEvents[5].payload["item"] as? [String: Any]
        XCTAssertEqual(thought?["type"] as? String, "reasoning")
        XCTAssertEqual(((thought?["summary"] as? [[String: Any]])?.first)?["text"] as? String, "Let me check.")
        let first = toolEvents[7].payload["item"] as? [String: Any], second = toolEvents[9].payload["item"] as? [String: Any]
        XCTAssertEqual(first?["type"] as? String, "function_call")
        XCTAssertEqual(first?["call_id"] as? String, "call_a")
        XCTAssertEqual(first?["name"] as? String, "exec_command")
        XCTAssertEqual(first?["arguments"] as? String, "{\"cmd\":\"ls\"}")
        XCTAssertEqual(second?["call_id"] as? String, "call_b")
        XCTAssertEqual(second?["arguments"] as? String, "{}")
        XCTAssertEqual(toolEvents[9].payload["output_index"] as? Int, 2)
        XCTAssertNil((toolEvents[10].payload["response"] as? [String: Any])?["usage"])

        // ── Façon Gemini : pas d'`index`, appel entier par fragment, signature à retenir, outil d'un espace de noms ──
        let namespaced: [[String: Any]] = [["type": "namespace", "name": "mcp__cua", "tools": [["type": "function", "name": "js"]]]]
        var bare = GatewayResponsesBridge.Stream(model: "m", tools: namespaced, extras: extras)
        frames = bare.ingest(line: chunk(#"{"choices":[{"delta":{"tool_calls":[{"id":"g1","type":"function","function":{"name":"mcp__cua__js","arguments":"{\"a\":1}"},"extra_content":{"google":{"thought_signature":"sig-G"}}}]}}]}"#))
        frames += bare.ingest(line: chunk(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"g2","type":"function","function":{"name":"exec_command","arguments":{"cmd":"pwd"}}}]}}]}"#))
        frames += bare.ingest(line: chunk(#"{"choices":[{"delta":{"tool_calls":[{"function":{"name":"view_image","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#))
        frames += bare.finish()
        let items = decode(frames).filter { $0.type == "response.output_item.done" }.compactMap { $0.payload["item"] as? [String: Any] }
        XCTAssertEqual(items.map { $0["name"] as? String }, ["js", "exec_command", "view_image"])
        XCTAssertEqual(items[0]["namespace"] as? String, "mcp__cua")
        XCTAssertNil(items[1]["namespace"])
        XCTAssertEqual(items[1]["arguments"] as? String, "{\"cmd\":\"pwd\"}")
        XCTAssertEqual((items[2]["call_id"] as? String)?.hasPrefix("call_"), true)
        XCTAssertEqual(((extras.get("g1") as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String, "sig-G")
        // Au tour suivant, la signature retenue repart avec l'appel.
        let replay = try! GatewayResponsesBridge.chatBody(["input": [["type": "function_call", "call_id": "g1", "name": "js", "namespace": "mcp__cua", "arguments": "{}"]]],
                                                          provider: gemini, model: "m", extras: extras)
        let replayed = ((replay["messages"] as! [[String: Any]])[0]["tool_calls"] as! [[String: Any]])[0]
        XCTAssertEqual(((replayed["extra_content"] as? [String: Any])?["google"] as? [String: Any])?["thought_signature"] as? String, "sig-G")

        // ── Erreur en cours de flux, flux vide, corps d'erreur ──
        var broken = GatewayResponsesBridge.Stream(model: "m", tools: nil, extras: extras)
        frames = broken.ingest(line: chunk(#"{"choices":[{"delta":{"content":"par"}}]}"#))
        frames += broken.ingest(line: chunk(#"{"error":{"message":"overloaded"}}"#))
        frames += broken.finish()
        let failed = decode(frames).last
        XCTAssertEqual(failed?.type, "response.failed")
        XCTAssertEqual(((failed?.payload["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String, "overloaded")
        var empty = GatewayResponsesBridge.Stream(model: "m", tools: nil, extras: extras)
        // Amont coupé sans marqueur de fin (modèle déchargé en pleine génération) : échec, jamais une réponse tronquée validée.
        XCTAssertEqual(decode(empty.finish()).map(\.type), ["response.created", "response.failed"])
        var cut = GatewayResponsesBridge.Stream(model: "m", tools: nil, extras: extras)
        frames = cut.ingest(line: chunk(#"{"choices":[{"delta":{"reasoning":"The user is asking"}}]}"#)) + cut.finish()
        XCTAssertEqual(decode(frames).last?.type, "response.failed")
        XCTAssertEqual(cut.failure, "Upstream stream ended before completion")
        var bare2 = GatewayResponsesBridge.Stream(model: "m", tools: nil, extras: extras)
        frames = bare2.ingest(line: chunk(#"{"choices":[{"delta":{"content":"ok"}}]}"#)) + bare2.ingest(line: chunk("[DONE]")) + bare2.finish()
        XCTAssertEqual(decode(frames).last?.type, "response.completed")
        XCTAssertNil(bare2.failure)
        XCTAssertEqual(GatewayResponsesBridge.errorMessage(Data(#"[{"error":{"code":402,"message":"credits depleted","status":"RESOURCE_EXHAUSTED"}}]"#.utf8)), "credits depleted")
        XCTAssertEqual(GatewayResponsesBridge.errorMessage(Data(#"{"error":{"message":"bad key"}}"#.utf8)), "bad key")
        XCTAssertEqual(GatewayResponsesBridge.errorMessage(Data("<html>502</html>".utf8)), "<html>502</html>")

        // Bibliothèque : le préfixe `models/` de Gemini reste dans l'identifiant, pas dans le nom.
        let listed = CloudProviders.models(for: gemini, entries: [["id": "models/gemini-x"]]).first
        XCTAssertEqual(listed?.id, "gemini/models/gemini-x")
        XCTAssertEqual(listed?.name, "gemini-x")
    }
}
