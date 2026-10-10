import Foundation
import Network

/// Compile independently (no app lifecycle, model loading, or real upstreams):
/// swiftc -D GATEWAY_STANDALONE -parse-as-library \
///   RailRouter/Models/ModelName.swift \
///   RailRouter/Services/UnifiedGateway.swift \
///   RailRouter/Tests/UnifiedGatewayTests.swift -o /tmp/jedi-gateway-tests
/// /tmp/jedi-gateway-tests
struct UnifiedGatewayTests {
    static func evaluate() async throws -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func head(_ headers: String, method: String = "POST") throws -> GatewayHTTPRequest {
            return try GatewayHTTPRequest.head(Data("\(method) /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n".utf8))
        }
        func rejects(_ headers: String, status: Int, method: String = "POST") {
            do { _ = try head(headers, method: method); check(false, "Expected framing rejection \(status)") }
            catch { check((error as? GatewayFailure)?.status == status, "Framing rejection \(status)") }
        }
        check(try head("Content-Length: 0\r\n").length == 0, "Zero-length body")
        check(try head("Content-Length: 3\r\nContent-Length: 3\r\n").length == 3, "Identical duplicate lengths accepted")
        check(try head("Content-Length: 3, 3\r\n").length == 3, "Identical comma lengths accepted")
        rejects("Content-Length: 1\r\nContent-Length: 2\r\n", status: 400)
        rejects("Content-Length: 1, 2\r\n", status: 400)
        rejects("Content-Length: 0\r\nTransfer-Encoding: chunked\r\n", status: 400)
        rejects("Transfer-Encoding: identity\r\n", status: 400)
        rejects("Content-Length: -1\r\n", status: 400)
        rejects("Content-Length: +1\r\n", status: 400)
        rejects("Content-Length: 1e4\r\n", status: 400)
        rejects("Content-Length: 99999999999999999999999\r\n", status: 400)
        rejects("Content-Length: \(GatewayHTTPRequest.bodyLimit + 1)\r\n", status: 413)
        check(try head("Content-Length: \(GatewayHTTPRequest.bodyLimit)\r\n").length == GatewayHTTPRequest.bodyLimit, "64 MiB boundary")
        rejects("", status: 411)
        rejects("Content-Length: 0\r\nExpect: 100-continue\r\n", status: 417)
        rejects("Content-Length : 0\r\n", status: 400)
        rejects("Content-Length: 0\r\nHost: other\r\n", status: 400)
        rejects("Content-Length: 0\r\n X-Fold: bad\r\n", status: 400)
        rejects("Content-Length: 0\r\nX-Bad: hi\nInjected: yes\r\n", status: 400)
        rejects("Content-Length: 0\r\nX-Huge: " + String(repeating: "a", count: GatewayHTTPRequest.headerLimit) + "\r\n", status: 431)

        let local = UnifiedGateway.filteredHeaders(["authorization": "secret", "cookie": "secret", "connection": "x-secret, keep-alive",
            "x-secret": "hidden", "transfer-encoding": "chunked", "content-length": "6", "host": "evil", "x-safe": "yes"], allowCredentials: false)
        check(local == ["x-safe": "yes"], "Credentials and hop-by-hop request fields removed")
        let desktop = ["accept": "text/event-stream", "x-oai-attestation": String(repeating: "a", count: 4000), "chatgpt-account-id": "id", "x-codex-turn-metadata": "{}"]
        check(UnifiedGateway.upstreamHeaders(desktop, source: "alibaba") == ["accept": "text/event-stream"], "Alibaba receives only accept (internal Codex headers made it answer 500)")
        check(UnifiedGateway.upstreamHeaders(desktop, source: "ollama").count == 4, "Local engines keep client headers")
        let bridgeHeaders = UnifiedGateway.filteredHeaders(["authorization": "secret", "cookie": "secret", "host": "evil"], allowCredentials: true)
        check(bridgeHeaders.count == 2, "Only OpenAI retains existing credentials")
        check(UnifiedGateway.filteredHeaders(["set-cookie": "secret", "content-encoding": "gzip", "x-safe": "yes"], allowCredentials: false, response: true) == ["x-safe": "yes"], "Local response cookies and decoded encoding removed")

        let catalog = GatewayCatalog(ollama: ["data": [["id": "qwen:8b"]]],
            lms: ["data": [["id": "studio-id"]]], openAI: ["data": [["id": "studio-id"], ["id": "cloud"]]],
            mlx: ["data": [["id": "mlx-community/Qwen3.8-27B-8bit"]]],
            mlxSchema: ["paths": ["/responses": ["post": [:]], "/v1/embeddings": ["post": [:]]]])
        check(catalog.models.count == 4, "Actual model feeds merge and deduplicate")
        check(catalog.models.contains { $0["id"] as? String == "mlx/mlx-community/Qwen3.8-27B-8bit" && $0["source"] as? String == "mlx" }, "MLX namespace and source")
        check(try UnifiedGateway.route(path: "/v1/chat/completions", model: "qwen:8b", catalog: catalog).port == 11434, "Colon routes to Ollama")
        check(try UnifiedGateway.route(path: "/v1/embeddings", model: "studio-id", catalog: catalog).source == "lmStudio", "Actual LM Studio identifier")
        let mlx = try UnifiedGateway.route(path: "/v1/responses", model: "mlx/mlx-community/Qwen3.8-27B-8bit", catalog: catalog)
        check(mlx.port == 8090 && mlx.model == "mlx-community/Qwen3.8-27B-8bit", "MLX Responses stays local and strips prefix")
        check(try UnifiedGateway.route(path: "/v1/responses", model: "mlx-community/Qwen3.8-27B-8bit", catalog: catalog).port == 8090, "Bare MLX ID never goes to legacy")
        check(try UnifiedGateway.route(path: "/v1/responses", model: "cloud", catalog: catalog).url.absoluteString == "https://chatgpt.com/backend-api/codex/responses", "OpenAI Responses uses one fixed authenticated URL")
        for model in ["unknown", "mlx/missing"] {
            do { _ = try UnifiedGateway.route(path: "/v1/chat/completions", model: model, catalog: catalog); check(false, "Unknown ID should fail") }
            catch { check((error as? GatewayFailure)?.status == 404, "No fallback for unknown model") }
        }
        check(try UnifiedGateway.route(path: "/v1/chat/completions", model: "http://evil", catalog: catalog).url.host == "127.0.0.1", "Model text cannot change upstream host")
        let clef = try UnifiedGateway.route(path: "/v1/systemone", model: "mlx/clef", catalog: catalog)
        check(clef.url.absoluteString == "http://127.0.0.1:8091/v1/systemone" && clef.model == "clef" && clef.source == "clef", "Clef decisions go to the MLX server on 8091")
        do { _ = try UnifiedGateway.route(path: "/v1/systemone", model: "qwen:8b", catalog: catalog); check(false, "Only clef answers /v1/systemone") }
        catch { check((error as? GatewayFailure)?.status == 404, "No other decision model") }
        do { _ = try UnifiedGateway.route(path: "/v1/chat/completions", model: "cloud", catalog: catalog); check(false, "OAuth chat unsupported") }
        catch { check((error as? GatewayFailure)?.status == 501, "OpenAI OAuth chat is explicit 501") }
        let router = try UnifiedGateway.route(path: "/v1/responses", model: "nvidia/nemotron-3-super-120b-a12b:free", catalog: catalog)
        check(router.source == "openrouter" && router.url.absoluteString == "https://openrouter.ai/api/v1/responses", "OpenRouter :free wins over the Ollama colon rule")
        check(try UnifiedGateway.route(path: "/v1/chat/completions", model: "openrouter/free", catalog: catalog).url.absoluteString == "https://openrouter.ai/api/v1/chat/completions", "OpenRouter chat URL")
        let freeIDs = GatewayOpenRouter.freeIDs(["data": [["id": "a/b:free"], ["id": "c/d"], ["id": "openrouter/free"]]])
        check((freeIDs["data"] as? [[String: Any]])?.count == 2, "Only free OpenRouter ids are listed")
        let none = URL(fileURLWithPath: "/nonexistent")
        check(GatewayOpenRouter.apiKey(environment: ["OPENROUTER_API_KEY": " k "], authFile: none, keyFile: none) == "k", "OpenRouter key from env")
        check(GatewayOpenRouter.apiKey(environment: [:], authFile: none, keyFile: none) == nil, "No OpenRouter key without config")
        let ali = try UnifiedGateway.route(path: "/v1/chat/completions", model: "alibaba/qwen-plus", catalog: catalog)
        check(ali.source == "alibaba" && ali.model == "qwen-plus" && ali.url.absoluteString == "https://ws-6yq2ck8vtygm4jna.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions", "Alibaba prefix is stripped and routed to Model Studio")
        check(try UnifiedGateway.route(path: "/v1/chat/completions", model: "alibaba/qwen3:8b", catalog: catalog).source == "alibaba", "Alibaba prefix wins over the Ollama colon rule")
        check(GatewayAlibaba.baseURL(environment: ["DASHSCOPE_BASE_URL": "https://h/compatible-mode/v1/"]) == "https://h/compatible-mode", "Alibaba base URL override")
        check(GatewayAlibaba.apiKey(environment: ["DASHSCOPE_API_KEY": " k "], keyFile: none) == "k" && GatewayAlibaba.apiKey(environment: [:], keyFile: none) == nil, "Alibaba key from env only")
        let aliCatalog = GatewayCatalog(alibaba: ["data": [["id": "qwen-plus"]]])
        check((aliCatalog.models.first?["id"] as? String) == "alibaba/qwen-plus", "Alibaba models are listed with the alibaba/ prefix")
        check(try UnifiedGateway.route(path: "/v1/responses", model: "qwen:8b", catalog: catalog).port == 11434, "Native Ollama Responses")
        check(try UnifiedGateway.route(path: "/v1/responses", model: "studio-id", catalog: catalog).port == 1234, "Native LM Studio Responses")
        let noResponses = GatewayCatalog(mlx: ["data": [["id": "m"]]])
        do { _ = try UnifiedGateway.route(path: "/v1/responses", model: "mlx/m", catalog: noResponses); check(false, "Unadvertised API") }
        catch { check((error as? GatewayFailure)?.status == 501, "Unadvertised MLX Responses is explicit 501") }
        do { _ = try UnifiedGateway.route(path: "/admin", model: "a:b", catalog: catalog); check(false, "Path allowlist") }
        catch { check((error as? GatewayFailure)?.status == 404, "Fixed-path allowlist") }

        let nativeCall: [String: Any] = ["type": "shell_call", "call_id": "native", "action": ["commands": ["pwd"]]]
        let adapted = try UnifiedGateway.localResponsesBody(["input": [
            ["type": "reasoning", "encrypted_content": "gAAAA-secret"],
            ["type": "custom_tool_call", "name": "apply_patch", "call_id": "call-a", "input": "patch"],
            ["type": "custom_tool_call_output", "call_id": "call-a", "output": "ok"], nativeCall],
            "tools": [["type": "custom", "name": "apply_patch"], ["type": "shell"]], "store": false], mlx: true)
        let adaptedInput = adapted["input"] as! [[String: Any]]
        check(adaptedInput.count == 3 && adaptedInput[0]["type"] as? String == "function_call", "Encrypted reasoning removed and custom call adapted")
        check(adaptedInput[0]["call_id"] as? String == "call-a" && adaptedInput[0]["arguments"] as? String == #"{"input":"patch"}"#, "Custom input and call ID preserved")
        check(adaptedInput[1]["type"] as? String == "function_call_output" && adaptedInput[2]["type"] as? String == "shell_call", "Native MLX calls preserved")
        check(adapted["store"] as? Bool == false && (adapted["tools"] as! [[String: Any]])[0]["type"] as? String == "function", "Native fields preserved, custom definition matches arguments")

        func usage(_ text: String, sse: Bool) -> GatewayUsageParser {
            var parser = GatewayUsageParser(sse: sse)
            for byte in text.utf8 { parser.ingest(byte) }
            parser.finish()
            return parser
        }
        let final = usage(#"{"usage":{"prompt_tokens":12,"completion_tokens":7},"output":"never retained"}"#, sse: false)
        check(final.promptTokens == 12 && final.completionTokens == 7, "Nonstream measured usage")
        let stream = usage("data: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":2}}\r\n\r\ndata: {\"response\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":7}}}\n\ndata: [DONE]\n\n", sse: true)
        check(stream.promptTokens == 12 && stream.completionTokens == 7, "SSE snapshots replace, never double count")
        let multiline = usage("data: {\"usage\":\n" + "data: {\"input_tokens\":0,\"output_tokens\":0}}\n\n", sse: true)
        check(multiline.promptTokens == 0 && multiline.completionTokens == 0, "Multiline event, measured zero")
        for text in [#"{"usage":null}"#, #"{"usage":{"prompt_tokens":true,"completion_tokens":-1}}"#,
                     #"{"usage":{"prompt_tokens":"13","completion_tokens":1.5}}"#, #"{"choices":[{"delta":{"content":"hello"}}]}"#] {
            let parser = usage(text, sse: false)
            check(parser.promptTokens == nil && parser.completionTokens == nil, "No invented usage")
        }
        let recovered = usage("data: " + String(repeating: "x", count: 1024 * 1024 + 1) + "\n\ndata: {\"usage\":{\"completion_tokens\":9}}\n\n", sse: true)
        check(recovered.completionTokens == 9, "Bounded SSE parser recovers after oversized event")

        let loaded = GatewayResidency(studio: ["data": [["id": "qwen/qwen3.8-27b", "state": "loaded"]]],
            mlx: ["loaded_model": "mlx-community/Qwen3.8-27B-8bit",
                  "loaded_models": ["text_generation": ["model": "mlx-community/Qwen3.8-27B-8bit"]]])
        check(loaded.models.count == 2, "MLX cache group names are not model identifiers")
        for source in ["ollama", "mlx", "lmStudio"] {
            do { try loaded.validate(source: source, model: source == "ollama" ? "qwen3.8:27b" : "mlx-community/Qwen3.8-27B-8bit"); check(false, "Cross-engine duplicate") }
            catch { check((error as? GatewayFailure)?.status == 409, "Duplicate even when target is already loaded") }
        }
        let onlyMLX = GatewayResidency(mlx: ["loaded_model": "mlx-community/Qwen3.8-27B-8bit"])
        try onlyMLX.validate(source: "mlx", model: "mlx-community/Qwen3.8-27B-8bit")
        check(true, "Exact resident MLX model allowed")
        do { try onlyMLX.validate(source: "mlx", model: "mlx-community/Qwen3.8-27B-4bit"); check(false, "Different quant must not load") }
        catch { check((error as? GatewayFailure)?.status == 409, "Different MLX quant cannot auto-load") }
        let unloadedStudio = GatewayResidency(studio: ["data": [["id": "qwen/qwen3.8-27b", "state": "not-loaded"]]])
        try unloadedStudio.validate(source: "ollama", model: "qwen3.8:27b")
        check(unloadedStudio.models.isEmpty, "Only loaded LM Studio models count as residents")
        do { try onlyMLX.validate(source: "ollama", model: "qwen3.8:27b"); check(false, "Expected suggestion") }
        catch { check((error as? GatewayFailure)?.message.contains("mlx/mlx-community/Qwen3.8-27B-8bit") == true, "409 suggests exact existing MLX identifier") }

        let compressed = Data(base64Encoded: "KLUv/QRYCQEAeyJtb2RlbCI6InF3ZW46OGIiLCJzdHJlYW0iOnRydWV9JDOr3w==")!
        let decoded = try GatewayZstd.decode(compressed, encoding: "zstd")
        check(String(decoding: decoded, as: UTF8.self) == #"{"model":"qwen:8b","stream":true}"#, "Installed zstd decodes Codex JSON without files or processes")
        let concatenated = try GatewayZstd.decode(compressed + compressed, encoding: "zstd")
        check(concatenated == decoded + decoded, "Concatenated zstd frames are fully bounded")
        let bomb = Data(base64Encoded: "KLUv/QRYTQAAEEFBAQD79wEWw1grbQ==")!
        do { _ = try GatewayZstd.decode(bomb, encoding: "zstd", limit: 1024); check(false, "Expansion limit") }
        catch { check((error as? GatewayFailure)?.status == 413, "Decompression bomb stops at configured bound") }
        for data in [Data("invalid".utf8), Data(compressed.dropLast(3)), Data()] {
            do { _ = try GatewayZstd.decode(data, encoding: "zstd"); check(false, "Invalid compressed input") }
            catch { check((error as? GatewayFailure)?.status == 400, "Invalid/truncated zstd is explicit 400") }
        }
        do { _ = try GatewayZstd.decode(decoded, encoding: "gzip"); check(false, "Unsupported encoding") }
        catch { check((error as? GatewayFailure)?.status == 415, "Unknown encoding explicit 415") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayMockProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        let upstreamSession = URLSession(configuration: configuration)
        defer { upstreamSession.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let telemetryFile = directory.appendingPathComponent("gateway.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var gateway: UnifiedGateway?
        var port: UInt16 = 0
        for _ in 0..<10 {
            port = UInt16.random(in: 49152...60000)
            let candidate = UnifiedGateway(port: port, session: upstreamSession, telemetryFile: telemetryFile)
            do { try candidate.start(); gateway = candidate; break } catch { candidate.stop() }
        }
        guard let gateway else { throw GatewayFailure(503, "Test listener unavailable") }
        defer { gateway.stop() }
        try gateway.start() // idempotent
        let occupied = UnifiedGateway(port: port, session: upstreamSession, telemetryFile: nil)
        do { try occupied.start(); check(false, "Occupied port should throw") } catch { check(true, "Bind failure is synchronous") }
        occupied.stop()
        let downstreamConfiguration = URLSessionConfiguration.ephemeral
        downstreamConfiguration.connectionProxyDictionary = [:]
        downstreamConfiguration.timeoutIntervalForRequest = 5
        let downstream = URLSession(configuration: downstreamConfiguration)
        defer { downstream.invalidateAndCancel() }
        func call(_ path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            if let body { request.httpMethod = "POST"; request.httpBody = body }
            request.setValue("test-auth-secret", forHTTPHeaderField: "Authorization")
            request.setValue("test-cookie-secret", forHTTPHeaderField: "Cookie")
            let (data, response) = try await downstream.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let health = try await call("/health")
        let healthJSON = try JSONSerialization.jsonObject(with: health.0) as! [String: Any]
        check(healthJSON["service"] as? String == "RailRouter" && healthJSON["legacyResponsesBridge"] as? Bool == false, "Real TCP health confirms native Responses")
        check(healthJSON["port"] as? Int == Int(port), "Bound listener advertises port")
        let listed = try await call("/v1/models")
        check((try JSONSerialization.jsonObject(with: listed.0) as! [String: Any])["data"] as? [[String: Any]] != nil, "Mock discovery through real TCP gateway")
        check(GatewayMockProtocol.captured().allSatisfy { $0.url?.absoluteString.hasPrefix(GatewayAlibaba.baseURL() + "/v1/models") == true || ($0.url?.host == "127.0.0.1" || $0.url?.absoluteString == "https://openrouter.ai/api/v1/models") && $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil }, "Discovery anonymous and fixed local hosts")
        let requestBody = Data(#"{"model":"qwen:8b","stream":true,"messages":[{"role":"user","content":"prompt-secret"}]}"#.utf8)
        let chat = try await call("/v1/chat/completions", body: requestBody)
        check(chat.1.statusCode == 200 && String(decoding: chat.0, as: UTF8.self).contains("[DONE]"), "SSE forwarded to EOF with original bytes")
        let chatUpstream = GatewayMockProtocol.captured().last { $0.url?.path == "/v1/chat/completions" }!
        check(chatUpstream.url?.port == 11434 && chatUpstream.value(forHTTPHeaderField: "Authorization") == nil && chatUpstream.value(forHTTPHeaderField: "Cookie") == nil, "Ollama receives no credentials")
        check(chat.1.value(forHTTPHeaderField: "Set-Cookie") == nil, "Local response cookie stripped")
        let bridgeBody = Data(#"{ "model": "gpt-test", "input": [{"type":"reasoning","encrypted_content":"gAAAA-exact"}] }"#.utf8)
        _ = try await call("/v1/responses", body: bridgeBody)
        let bridge = GatewayMockProtocol.captured().last { $0.url?.host == "chatgpt.com" }!
        check(bridge.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses" && String(decoding: GatewayMockProtocol.body(bridge), as: UTF8.self).contains("gAAAA-exact"), "Native OpenAI preserves encrypted reasoning on fixed target")
        check(bridge.value(forHTTPHeaderField: "Authorization") == "test-auth-secret" && bridge.value(forHTTPHeaderField: "Cookie") == "test-cookie-secret", "Caller auth only to fixed OpenAI route")
        let mlxBody = Data(#"{"model":"mlx/mlx-community/Qwen3.8-27B-8bit","input":[{"type":"reasoning","encrypted_content":"gAAAA-secret"},{"type":"message","role":"user","content":"prompt-secret"}]}"#.utf8)
        _ = try await call("/v1/responses", body: mlxBody)
        let mlxRequest = GatewayMockProtocol.captured().last { $0.url?.path == "/v1/responses" }!
        let mlxJSON = try JSONSerialization.jsonObject(with: GatewayMockProtocol.body(mlxRequest)) as! [String: Any]
        check(mlxRequest.url?.port == 8090 && mlxJSON["model"] as? String == "mlx-community/Qwen3.8-27B-8bit", "Actual MLX model rewrite")
        check(mlxRequest.value(forHTTPHeaderField: "Authorization") == nil && !String(decoding: GatewayMockProtocol.body(mlxRequest), as: UTF8.self).contains("gAAAA"), "MLX Responses strips credentials and encrypted reasoning")
        let embeddings = try await call("/v1/embeddings", body: Data(#"{"model":"studio-id","input":"prompt-secret"}"#.utf8))
        check(embeddings.1.statusCode == 200 && GatewayMockProtocol.captured().last { $0.url?.path == "/v1/embeddings" }?.url?.port == 1234, "LM Studio embeddings use discovered identifier")
        let unknown = try await call("/v1/chat/completions", body: Data(#"{"model":"unknown"}"#.utf8))
        check(unknown.1.statusCode == 404, "Unknown model HTTP 404")
        let badJSON = try await call("/v1/responses", body: Data("{bad".utf8))
        check(badJSON.1.statusCode == 400, "Malformed JSON HTTP 400")
        let forbidden = try await call("/v1/../../evil")
        check(forbidden.1.statusCode == 404, "Unlisted HTTP path blocked")
        let telemetry = try await call("/telemetry")
        let envelope = try JSONSerialization.jsonObject(with: telemetry.0) as! [String: Any]
        let requests = envelope["requests"] as! [[String: Any]]
        check(requests.count == 4 && requests.allSatisfy { $0["phase"] as? String == "completed" && $0["startedAt"] is NSNumber && $0["finishedAt"] is NSNumber }, "Frozen telemetry envelope and Unix timestamps")
        check(requests[0]["promptTokens"] as? Int == 12 && requests[0]["completionTokens"] as? Int == 7, "Final SSE actual usage in telemetry")
        check(requests.contains { $0["source"] as? String == "mlx" && $0["upstreamModel"] as? String == "mlx-community/Qwen3.8-27B-8bit" }, "Exact upstream attribution")
        let calls = envelope["calls"] as? [String: Int] ?? [:]
        check(calls.values.reduce(0, +) >= requests.count && calls["mlx|mlx-community/Qwen3.8-27B-8bit"] != nil, "Per-model call counts in telemetry")
        let persisted = try Data(contentsOf: telemetryFile)
        check(persisted == telemetry.0, "Telemetry persisted atomically with same contract")
        let telemetryText = String(decoding: persisted, as: UTF8.self)
        check(!telemetryText.contains("prompt-secret") && !telemetryText.contains("output-secret") && !telemetryText.contains("test-auth") && !telemetryText.contains("gAAAA"), "No prompts, output or credentials persisted")

        let raw = try await GatewayTestWire.exchange(port: port, request: Data("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n".utf8))
        check(String(decoding: raw, as: UTF8.self).hasPrefix("HTTP/1.1 400"), "Conflicting framing rejected over TCP")
        let huge = try await GatewayTestWire.exchange(port: port, request: Data("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: 67108865\r\n\r\n".utf8))
        check(String(decoding: huge, as: UTF8.self).hasPrefix("HTTP/1.1 413"), "Oversize rejected before body read")
        var compressedRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        compressedRequest.httpMethod = "POST"
        compressedRequest.httpBody = compressed
        compressedRequest.setValue("zstd", forHTTPHeaderField: "Content-Encoding")
        _ = try await downstream.data(for: compressedRequest)
        let decodedUpstream = GatewayMockProtocol.captured().last { $0.url?.path == "/v1/chat/completions" }!
        check(GatewayMockProtocol.body(decodedUpstream) == decoded && decodedUpstream.value(forHTTPHeaderField: "Content-Encoding") == nil, "Compressed routing removes encoding after bounded decode")
        let blocked = try await call("/v1/chat/completions", body: Data(#"{"model":"qwen3.8:27b"}"#.utf8))
        check(blocked.1.statusCode == 409, "Real TCP request blocked by resident MLX family")
        check(!GatewayMockProtocol.captured().contains { $0.url?.path == "/v1/chat/completions" && String(decoding: GatewayMockProtocol.body($0), as: UTF8.self).contains("qwen3.8:27b") }, "409 triggers no upstream inference")
        let studioResponses = try await call("/v1/responses", body: Data(#"{"model":"studio-id","input":[{"type":"reasoning","encrypted_content":"gAAAA-remove"},{"type":"custom_tool_call","name":"apply_patch","input":"fixture"}]}"#.utf8))
        check(studioResponses.1.statusCode == 200, "Native LM Studio Responses forwards")
        let studioRequest = GatewayMockProtocol.captured().last { $0.url?.path == "/v1/responses" }!
        let studioBody = String(decoding: GatewayMockProtocol.body(studioRequest), as: UTF8.self)
        check(studioRequest.url?.port == 1234 && studioRequest.value(forHTTPHeaderField: "Authorization") == nil && !studioBody.contains("gAAAA") && studioBody.contains("function_call"), "All local Responses sanitizes Codex history")
        let openAIAdapter = UnifiedGateway.openAIResponsesBody(["input": [["type": "reasoning", "summary": "local plaintext"], ["type": "reasoning", "encrypted_content": "gAAAA-preserve"], ["type": "custom_tool_call", "input": "native"]]])
        check((openAIAdapter["input"] as! [[String: Any]]).count == 2, "OpenAI strips local reasoning and preserves native custom calls")
        let before = GatewayMockProtocol.stoppedCount()
        _ = try await GatewayTestWire.exchange(port: port, request: Data("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: 40\r\n\r\n{\"model\":\"cancel:fixture\",\"stream\":true}".utf8), disconnectAfterFirst: true)
        try await Task.sleep(for: .milliseconds(250))
        check(GatewayMockProtocol.stoppedCount() > before, "Disconnect cancels URLSession producer")
        let phases = await gateway.telemetrySnapshot()
        check(phases.last?.phase == "failed", "Disconnected request reaches terminal failed phase")
        for _ in 0..<101 { _ = try await call("/v1/embeddings", body: Data(#"{"model":"studio-id","input":"fixture"}"#.utf8)) }
        check(await gateway.telemetrySnapshot().count == 100, "Recent telemetry strictly bounded at 100 requests")
        check(!GatewayMockProtocol.captured().contains { $0.url?.port == 41234 }, "No gateway request ever targets old router")
        gateway.stop()
        try gateway.start()
        check(try await call("/health").1.statusCode == 200, "Stop/start lifecycle")
        do { try UnifiedGateway(port: 41234, session: upstreamSession, telemetryFile: nil).start(); check(false, "Reserved port") }
        catch { check((error as? GatewayFailure)?.status == 400, "Existing router port cannot be bound") }
        return (checks, failures)
    }
}

private final class GatewayMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var stopped = 0
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func stoppedCount() -> Int { lock.lock(); defer { lock.unlock() }; return stopped }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var result = Data()
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count)) }
        return result
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        var content: String
        var sse = false
        if url.path == "/v1/models" {
            switch url.port {
            case 11434: content = #"{"data":[{"id":"qwen:8b"}]}"#
            case 1234: content = #"{"data":[{"id":"studio-id"}]}"#
            case 8090: content = #"{"data":[{"id":"mlx-community/Qwen3.8-27B-8bit"}]}"#
            default: content = #"{"data":[{"id":"cloud"}]}"#
            }
        } else if url.path == "/api/ps" { content = #"{"models":[]}"# }
        else if url.path == "/api/v0/models" { content = #"{"data":[]}"# }
        else if url.path == "/health" { content = #"{"loaded_model":"mlx-community/Qwen3.8-27B-8bit"}"# }
        else if url.path == "/openapi.json" { content = #"{"paths":{"/responses":{"post":{}},"/v1/embeddings":{"post":{}}}}"# }
        else if url.path == "/v1/chat/completions" {
            sse = true
            content = "data: {\"choices\":[{\"delta\":{\"content\":\"output-secret\"}}]}\n\ndata: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":7}}\n\ndata: [DONE]\n\n"
        } else { content = #"{"output":"output-secret","usage":{"input_tokens":12,"output_tokens":7}}"# }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": sse ? "text/event-stream" : "application/json", "Set-Cookie": "upstream-cookie"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/v1/chat/completions", String(decoding: Self.body(request), as: UTF8.self).contains("cancel:fixture") {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[]}\n\n".utf8))
            return // intentionally leave producer pending until client disconnects
        }
        client?.urlProtocol(self, didLoad: Data(content.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stopped += 1; Self.lock.unlock() }
}

private final class GatewayTestWire: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gateway.test.wire")
    private let connection: NWConnection
    private var result = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var disconnect = false
    private var timeout: DispatchWorkItem?
    private init(port: UInt16) { connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    static func exchange(port: UInt16, request: Data, disconnectAfterFirst: Bool = false) async throws -> Data {
        let wire = Self(port: port)
        return try await withCheckedThrowingContinuation { continuation in
            wire.queue.async {
                wire.continuation = continuation
                wire.disconnect = disconnectAfterFirst
                wire.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        wire.connection.send(content: request, completion: .contentProcessed { error in
                            if let error { wire.finish(error) } else { wire.receive() }
                        })
                    case .failed(let error): wire.finish(error)
                    default: break
                    }
                }
                let timeout = DispatchWorkItem { wire.finish(GatewayFailure(504, "Wire fixture timed out")) }
                wire.timeout = timeout
                wire.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                wire.connection.start(queue: wire.queue)
            }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, ended, error in
            if let data { result.append(data) }
            if let error { finish(error) }
            else if ended || (disconnect && result.range(of: Data("\n\n".utf8)) != nil) { finish(nil) }
            else { receive() }
        }
    }
    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result) }
    }
}

#if GATEWAY_STANDALONE
@main private struct GatewayTestMain {
    static func main() async {
        do {
            let result = try await UnifiedGatewayTests.evaluate()
            for failure in result.failures { print("FAIL: \(failure)") }
            print("Gateway: \(result.checks) checks, \(result.failures.count) failures; fixtures only")
            exit(result.failures.isEmpty ? 0 : 1)
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
#endif
