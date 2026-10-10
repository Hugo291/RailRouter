import Foundation
import Network
import Darwin

/// A loopback-only, single-request HTTP gateway. The helper must retain this
/// instance and keep its process alive (e.g. dispatchMain); no UI/run-loop needed.
final class UnifiedGateway: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "RailRouter.gateway.network", qos: .utility)
    private let session: URLSession
    private let telemetry: GatewayTelemetry
    private let mlxActivityFile: URL?
    private let openAICatalogFile: URL?
    private let providerEnvironment: [String: String]
    private let providerKeyFile: URL
    private let metadataCache = GatewayMetadataCache()
    private let residencyGate = GatewayResidencyGate()
    private var listener: NWListener?
    private var peers: [UUID: GatewayPeer] = [:] // queue-owned

    init(port: UInt16 = 41235) {
        self.port = port
        openAICatalogFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/local-models/catalog.json")
        providerEnvironment = ProcessInfo.processInfo.environment
        providerKeyFile = CloudProviders.keyFile
        mlxActivityFile = GatewayMLXActivity.defaultFile
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
        telemetry = GatewayTelemetry(file: GatewayTelemetry.defaultFile)
    }

    /// Test seam: an ephemeral session with URLProtocol fixtures; never a model call.
    init(port: UInt16, session: URLSession, telemetryFile: URL?) {
        self.port = port
        self.session = session
        openAICatalogFile = nil
        providerEnvironment = [:]
        providerKeyFile = URL(fileURLWithPath: "/nonexistent/provider-keys.json")
        mlxActivityFile = nil // fixtures must never refresh the real model watchdog
        telemetry = GatewayTelemetry(file: telemetryFile)
    }

    func start() throws {
        guard port != 0, port != 41234 else { throw GatewayFailure(400, "Reserved or invalid gateway port") }
        let ready = DispatchSemaphore(value: 0)
        let outcome = GatewayStartOutcome()
        let created = try queue.sync { () throws -> Bool in
            guard listener == nil else { return false }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            parameters.requiredInterfaceType = .loopback
            let newListener = try NWListener(using: parameters)
            listener = newListener
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready: outcome.finish(nil, semaphore: ready)
                case .failed(let error): outcome.finish(error, semaphore: ready)
                case .cancelled: outcome.finish(CancellationError(), semaphore: ready)
                default: break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self, self.peers.count < 128 else { connection.cancel(); return }
                let peer = GatewayPeer(connection: connection, gateway: self, queue: self.queue)
                self.peers[peer.id] = peer
                peer.start()
            }
            newListener.start(queue: queue)
            return true
        }
        // If already running, start is idempotent. Listener readiness is otherwise
        // confirmed so bind failures are thrown instead of disappearing in a callback.
        if !created { return }
        guard ready.wait(timeout: .now() + 5) == .success else { stop(); throw GatewayFailure(503, "Gateway bind timed out") }
        if let error = outcome.error { stop(); throw error }
    }

    func stop() {
        let cancelled = DispatchSemaphore(value: 0)
        let hadListener = queue.sync { () -> Bool in
            let old = listener
            listener = nil
            if let old {
                old.stateUpdateHandler = { state in
                    if case .cancelled = state { cancelled.signal() }
                    if case .failed = state { cancelled.signal() }
                }
                old.cancel()
            }
            for peer in Array(peers.values) { peer.close() }
            peers.removeAll()
            return old != nil
        }
        if hadListener { _ = cancelled.wait(timeout: .now() + 5) }
    }

    func telemetrySnapshot() async -> [GatewayRequestTelemetry] { await telemetry.snapshot() }

    fileprivate func remove(_ id: UUID) { peers[id] = nil }

    fileprivate func handle(_ request: GatewayHTTPRequest, peer: GatewayPeer) async {
        var record: GatewayRequestTelemetry?
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                try await peer.json(["service": "RailRouter", "gateway": "UnifiedGateway", "port": port,
                                     "legacyResponsesBridge": false])
            case ("GET", "/telemetry"):
                try await peer.jsonData(await telemetry.json())
            case ("GET", "/v1/models"):
                let catalog = await discover()
                try Task.checkCancellation()
                try await peer.json(["object": "list", "data": catalog.models])
            case ("POST", "/v1/chat/completions"), ("POST", "/v1/embeddings"), ("POST", "/v1/responses"), ("POST", "/v1/systemone"):
                let decodedBody = try GatewayZstd.decode(request.body, encoding: request.headers["content-encoding"])
                guard let object = (try? JSONSerialization.jsonObject(with: decodedBody)) as? [String: Any] else {
                    throw GatewayFailure(400, "Expected a JSON object")
                }
                let model = object["model"] as? String
                guard let model, !model.isEmpty, model.utf8.count <= 1024 else {
                    throw GatewayFailure(400, "A model ID of at most 1024 bytes is required")
                }
                let catalog: GatewayCatalog
                // Colon IDs route deterministically; exact IDs use cached metadata.
                if model.contains(":"), !model.hasPrefix("mlx/") {
                    catalog = GatewayCatalog()
                } else { catalog = await discover() }
                try Task.checkCancellation()
                let route = try Self.route(path: request.path, model: model, catalog: catalog)
                record = GatewayRequestTelemetry(id: peer.id, path: request.path, model: model, upstreamModel: route.source == "openai" ? nil : route.model, source: route.source)
                await telemetry.begin(record!)
                var body = decodedBody
                if route.source == "mlx" {
                    guard object["adapter_path"] == nil || object["adapter_path"] is NSNull else {
                        throw GatewayFailure(400, "Gateway does not load MLX adapter weights")
                    }
                    var rewritten = request.path == "/v1/responses" ? try Self.localResponsesBody(object, mlx: true) : object
                    rewritten["model"] = route.model
                    body = try JSONSerialization.data(withJSONObject: rewritten)
                }
                if request.path == "/v1/responses", route.source != "mlx" {
                    let normalized = route.source == "openai" ? Self.openAIResponsesBody(object) : try Self.localResponsesBody(object, mlx: false)
                    body = try JSONSerialization.data(withJSONObject: normalized)
                }
                if route.source == "alibaba" || route.source == "clef" || CloudProviders.generic(id: route.source) != nil {
                    // Exposed as `alibaba/<id>` / `deepseek/<id>` / `mlx/clef`; the upstream only knows `<id>`.
                    var rewritten = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? object
                    rewritten["model"] = route.model
                    body = try JSONSerialization.data(withJSONObject: rewritten)
                }
                if !["openai", "openrouter", "alibaba"].contains(route.source), CloudProviders.generic(id: route.source) == nil,
                   let raw = route.model {
                    let source = route.source
                    let residency = await residentModels()
                    try Task.checkCancellation()
                    try await residencyGate.acquire(id: peer.id, source: source, model: raw, residency: residency)
                }
                defer { Task { await residencyGate.release(peer.id) } }
                var upstream = URLRequest(url: route.url)
                upstream.httpMethod = "POST"
                upstream.httpBody = body
                for (name, value) in Self.upstreamHeaders(request.headers, source: route.source) {
                    upstream.setValue(value, forHTTPHeaderField: name)
                }
                if route.source == "openrouter" {
                    // The client's Authorization (ChatGPT token) is stripped above; OpenRouter gets its own key.
                    guard let key = GatewayOpenRouter.apiKey() else {
                        throw GatewayFailure(401, "No OpenRouter key: set OPENROUTER_API_KEY or run `opencode auth login`")
                    }
                    upstream.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                }
                if route.source == "alibaba" {
                    guard let key = GatewayAlibaba.apiKey() else {
                        throw GatewayFailure(401, "No Alibaba key: set DASHSCOPE_API_KEY (launchctl setenv for the LaunchAgent)")
                    }
                    upstream.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                }
                if let provider = CloudProviders.generic(id: route.source) {
                    guard let key = CloudProviders.apiKey(for: provider.id, environment: providerEnvironment, file: providerKeyFile) else {
                        throw GatewayFailure(401, "No \(provider.name) key: connect it in RailRouter (Endpoint, Fournisseurs) or set \(provider.keyVariable)")
                    }
                    for (name, value) in provider.authHeaders(key: key) { upstream.setValue(value, forHTTPHeaderField: name) }
                }
                upstream.setValue(nil, forHTTPHeaderField: "Content-Encoding")
                upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
                upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                upstream.httpShouldHandleCookies = false
                let activity = route.source == "mlx" ? GatewayMLXActivity(file: mlxActivityFile) : nil
                defer { activity?.stop() }
                let (bytes, response) = try await session.bytes(for: upstream, delegate: GatewayNoRedirect())
                // Explicitly cancel AsyncBytes.task too: cancellation after headers
                // must terminate the producer while a downstream send is suspended.
                peer.track(bytes.task)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse else { throw GatewayFailure(502, "Invalid upstream response") }
                let sse = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
                var usage = GatewayUsageParser(sse: sse)
                try await peer.responseHead(response, allowCredentials: route.source == "openai")
                record?.status = response.statusCode
                record?.phase = "generating" // proxy phase: headers received, body forwarding starts
                await telemetry.update(record!)
                var chunk = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    usage.ingest(byte)
                    chunk.append(byte)
                    // SSE flushes each line promptly, including [DONE]; other bodies
                    // have a fixed 16 KiB buffer. Each send completes before reading on.
                    if chunk.count >= 16 * 1024 || (sse && byte == 10) {
                        try await peer.send(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await peer.send(chunk) }
                usage.finish()
                if let reported = usage.reportedModel { record?.upstreamModel = reported }
                record?.promptTokens = usage.promptTokens
                record?.completionTokens = usage.completionTokens
                record?.phase = response.statusCode < 400 ? "completed" : "failed"
                record?.finishedAt = Date()
                await telemetry.update(record!)
            default: throw GatewayFailure(404, "Unknown gateway endpoint")
            }
            await peer.finish()
        } catch {
            if var failed = record {
                failed.phase = "failed"
                failed.status = (error as? GatewayFailure)?.status ?? failed.status ?? 502
                failed.finishedAt = Date()
                await telemetry.update(failed)
            }
            if !Task.isCancelled {
                let failure = error as? GatewayFailure ?? GatewayFailure(502, "Local upstream unavailable")
                try? await peer.json(["error": ["message": failure.message, "type": "gateway_error"]], status: failure.status)
            }
            await peer.finish()
        }
    }

    private func discover() async -> GatewayCatalog {
        if let cached = metadataCache.get() { return cached }
        async let ollama = fetchJSON(port: 11434, path: "/v1/models")
        async let lms = fetchJSON(port: 1234, path: "/v1/models")
        async let mlx = fetchJSON(port: 8090, path: "/v1/models")
        async let openRouter = GatewayOpenRouter.freeCatalog(session: session)
        async let alibaba = GatewayAlibaba.catalog(session: session)
        async let clouds = CloudProviders.catalogs(session: session, environment: providerEnvironment, keyFile: providerKeyFile)
        // Passive capability discovery: never probes POST or triggers inference.
        async let schema = fetchJSON(port: 8090, path: "/openapi.json")
        let catalog = await GatewayCatalog(ollama: ollama, lms: lms, openAI: Self.openAICatalog(openAICatalogFile), openRouter: await openRouter, alibaba: await alibaba, clouds: await clouds, mlx: mlx, mlxSchema: schema)
        metadataCache.put(catalog)
        return catalog
    }

    /// Read slug metadata only; never contact OpenAI to discover OpenAI models.
    static func openAICatalog(_ file: URL?) -> [String: Any] {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2 * 1024 * 1024 + 1), data.count <= 2 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [:] }
        return ["data": models.compactMap { item -> [String: Any]? in
            guard let slug = item["slug"] as? String, !slug.isEmpty else { return nil }
            return ["id": slug, "owned_by": "openai"]
        }]
    }

    private func residentModels() async -> GatewayResidency {
        async let ollama = fetchJSON(port: 11434, path: "/api/ps")
        async let studio = fetchJSON(port: 1234, path: "/api/v0/models")
        async let mlx = fetchJSON(port: 8090, path: "/health")
        return await GatewayResidency(ollama: ollama, studio: studio, mlx: mlx)
    }

    private func fetchJSON(port: UInt16, path: String) async -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 3
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: GatewayNoRedirect())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return [:] }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 2 * 1024 * 1024 else { return [:] }
                data.append(byte)
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch { return [:] }
    }

    static func route(path: String, model: String?, catalog: GatewayCatalog) throws -> GatewayRoute {
        guard ["/v1/responses", "/v1/chat/completions", "/v1/embeddings", "/v1/systemone"].contains(path) else {
            throw GatewayFailure(404, "Unknown route")
        }
        if path == "/v1/systemone" {
            // Decision model Clef (MLX), served on 8091 by ~/.ai/skills/use-decision/scripts/clef-server.sh;
            // like MLX on 8090, the gateway never starts it or loads weights.
            guard model == "clef" || model == "mlx/clef" else { throw GatewayFailure(404, "Decision model: clef (MLX, port 8091)") }
            return GatewayRoute(port: 8091, path: path, source: "clef", model: "clef")
        }
        if let model, model.hasPrefix("mlx/") || catalog.mlxIDs.contains(model) || model.hasPrefix("mlx-community/") {
            let raw = model.hasPrefix("mlx/") ? String(model.dropFirst(4)) : model
            guard catalog.mlxIDs.contains(raw) else { throw GatewayFailure(404, "MLX model is not served on port 8090") }
            guard catalog.mlxPaths.contains(path) else {
                throw GatewayFailure(501, "MLX does not advertise this API; use /v1/chat/completions")
            }
            return GatewayRoute(port: 8090, path: path, source: "mlx", model: raw)
        }
        guard let model, !model.isEmpty else { throw GatewayFailure(400, "A model ID is required") }
        if model.hasPrefix("alibaba/"), model.count > 8 {
            return GatewayRoute(port: 443, path: path, source: "alibaba", model: String(model.dropFirst(8)))
        }
        if isOpenRouterID(model, catalog: catalog) {
            return GatewayRoute(port: 443, path: path, source: "openrouter", model: model)
        }
        // After OpenRouter: its ids also start with a vendor (`deepseek/…:free`) and must stay on OpenRouter.
        if let (provider, upstream) = CloudProviders.route(model: model) {
            return GatewayRoute(port: 443, path: path, source: provider.id, model: upstream)
        }
        if model.contains(":") { return GatewayRoute(port: 11434, path: path, source: "ollama", model: model) }
        if catalog.lmsIDs.contains(model) { return GatewayRoute(port: 1234, path: path, source: "lmStudio", model: model) }
        if catalog.openAIIDs.contains(model) || model.hasPrefix("gpt-") || model == "codex-auto-review" {
            guard path == "/v1/responses" else {
                throw GatewayFailure(501, "ChatGPT OAuth models require /v1/responses; chat/completions and embeddings are not supported")
            }
            return GatewayRoute(port: 443, path: path, source: "openai", model: model)
        }
        throw GatewayFailure(404, "Unknown local model ID")
    }

    /// OpenRouter ids: `…:free` (Ollama tags never use it), `openrouter/…`, or a listed free model.
    static func isOpenRouterID(_ model: String, catalog: GatewayCatalog) -> Bool {
        catalog.openRouterIDs.contains(model) || model.hasSuffix(":free") || model.hasPrefix("openrouter/")
    }

    /// Adapt only the Codex-only items that the installed MLX normalizer lacks.
    /// Native function/shell/apply_patch calls and all remaining request fields survive.
    static func localResponsesBody(_ object: [String: Any], mlx: Bool) throws -> [String: Any] {
        var result = object
        if let input = object["input"] as? [[String: Any]] {
            result["input"] = try input.compactMap { item -> [String: Any]? in
                switch item["type"] as? String ?? "message" {
                case "custom_tool_call":
                    let arguments = try JSONSerialization.data(withJSONObject: ["input": item["input"] ?? ""])
                    var call = item
                    call["type"] = "function_call"
                    call["arguments"] = String(decoding: arguments, as: UTF8.self)
                    call["input"] = nil
                    return call
                case "custom_tool_call_output":
                    var output = item
                    output["type"] = "function_call_output"
                    return output
                case "reasoning":
                    return item["encrypted_content"] == nil ? item : nil
                case "message", "function_call", "function_call_output": return item
                case "shell_call", "shell_call_output", "apply_patch_call", "apply_patch_call_output", "tool_result":
                    return mlx ? item : nil
                default: return nil // same removal of OpenAI-only history as legacy for_local
                }
            }
        }
        if mlx, let tools = object["tools"] as? [[String: Any]] {
            result["tools"] = try tools.map { tool -> [String: Any] in
                if tool["type"] as? String == "custom" {
                    var converted: [String: Any] = ["type": "function",
                        "parameters": ["type": "object", "properties": ["input": ["type": "string"]], "required": ["input"]]]
                    converted["name"] = tool["name"]
                    converted["description"] = tool["description"]
                    return converted
                }
                guard ["function", "shell", "apply_patch"].contains(tool["type"] as? String ?? "") else {
                    throw GatewayFailure(501, "MLX does not support this Responses tool type")
                }
                return tool
            }
        }
        if mlx, var choice = object["tool_choice"] as? [String: Any], choice["type"] as? String == "custom" {
            choice["type"] = "function"
            result["tool_choice"] = choice
        }
        return result
    }

    static func openAIResponsesBody(_ object: [String: Any]) -> [String: Any] {
        var result = object
        if let items = object["input"] as? [[String: Any]] {
            result["input"] = items.filter { item in
                item["type"] as? String != "reasoning" || (item["encrypted_content"] as? String)?.hasPrefix("gAAAA") == true
            }
        }
        return result
    }

    /// Third-party clouds (Alibaba, OpenRouter, keyed providers) get only `accept`: Codex Desktop adds ~5 KB of internal headers
    /// (attestation, account and session ids) and Alibaba answers 500 "No gRPC response received" past that size.
    static func upstreamHeaders(_ headers: [String: String], source: String) -> [String: String] {
        let all = filteredHeaders(headers, allowCredentials: source == "openai")
        return ["alibaba", "openrouter"].contains(source) || CloudProviders.generic(id: source) != nil
            ? all.filter { $0.key.lowercased() == "accept" } : all
    }

    static func filteredHeaders(_ headers: [String: String], allowCredentials: Bool, response: Bool = false) -> [String: String] {
        var excluded: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                     "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host", "expect"]
        for token in (headers["connection"] ?? "").split(separator: ",") {
            excluded.insert(token.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if !allowCredentials { excluded.formUnion(["authorization", "cookie", "cookie2", "set-cookie", "set-cookie2"]) }
        // URLSession decompresses encoded responses; wire framing is regenerated.
        if response { excluded.insert("content-encoding") }
        return headers.filter { !excluded.contains($0.key.lowercased()) && !$0.value.contains("\r") && !$0.value.contains("\n") }
    }
}

struct GatewayFailure: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

struct GatewayRoute {
    let port: UInt16
    let path: String
    let source: String
    let model: String?
    var url: URL {
        if source == "openai" { return URL(string: "https://chatgpt.com/backend-api/codex/responses")! }
        if source == "openrouter" { return URL(string: "https://openrouter.ai/api" + path)! }
        if source == "alibaba" { return URL(string: GatewayAlibaba.baseURL() + path)! }
        // `path` always starts with `/v1`; each provider's base URL already carries its own version prefix.
        if let provider = CloudProviders.generic(id: source) { return URL(string: provider.baseURL + path.dropFirst(3))! }
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
}

struct GatewayCatalog {
    var models: [[String: Any]] = []
    var openAIIDs: Set<String> = []
    var openRouterIDs: Set<String> = []
    var ollamaIDs: Set<String> = []
    var lmsIDs: Set<String> = []
    var mlxIDs: Set<String> = []
    var mlxPaths: Set<String> = []

    init(ollama: [String: Any] = [:], lms: [String: Any] = [:], openAI: [String: Any] = [:], openRouter: [String: Any] = [:], alibaba: [String: Any] = [:],
         clouds: [String: [String: Any]] = [:], mlx: [String: Any] = [:], mlxSchema: [String: Any] = [:]) {
        let paths = mlxSchema["paths"] as? [String: Any] ?? [:]
        for path in ["/v1/chat/completions", "/v1/embeddings", "/v1/responses"] {
            let alias = String(path.dropFirst(3))
            let route = paths[path] as? [String: Any] ?? paths[alias] as? [String: Any]
            if route?["post"] != nil { mlxPaths.insert(path) }
        }
        // Chat is the established common MLX server API; less universal APIs
        // (Responses/embeddings) must be advertised by its actual OpenAPI document.
        mlxPaths.insert("/v1/chat/completions")
        var positions: [String: Int] = [:]
        for (source, port, payload) in [("ollama", 11434, ollama), ("lmStudio", 1234, lms), ("mlx", 8090, mlx), ("openai", 443, openAI), ("openrouter", 443, openRouter), ("alibaba", 443, alibaba)]
            + clouds.sorted { $0.key < $1.key }.map({ ($0.key, 443, $0.value) }) {
            for item in payload["data"] as? [[String: Any]] ?? [] {
                guard let raw = item["id"] as? String, !raw.isEmpty, raw.utf8.count <= 1024 else { continue }
                if source == "openai" { openAIIDs.insert(raw) }
                if source == "openrouter" { openRouterIDs.insert(raw) }
                if source == "ollama" { ollamaIDs.insert(raw) }
                if source == "lmStudio" { lmsIDs.insert(raw) }
                if source == "mlx" { mlxIDs.insert(raw) }
                let id = source == "mlx" ? "mlx/" + raw : source == "alibaba" || clouds[source] != nil ? source + "/" + raw : raw
                let sourceInfo: [String: Any] = ["source": source, "port": port, "upstream_id": raw]
                if let index = positions[id] {
                    var sources = models[index]["gateway_sources"] as? [[String: Any]] ?? []
                    sources.append(sourceInfo)
                    models[index]["gateway_sources"] = sources
                } else {
                    // Only model metadata is copied, never arbitrary upstream extras.
                    var model: [String: Any] = ["id": id, "object": "model", "owned_by": item["owned_by"] as? String ?? source,
                                                "source": source, "upstreamModel": raw, "gateway_source": source, "gateway_sources": [sourceInfo]]
                    if let created = item["created"] as? NSNumber { model["created"] = created }
                    if source == "mlx" { model["gateway_paths"] = mlxPaths.sorted() }
                    positions[id] = models.count
                    models.append(model)
                }
            }
        }
    }
}

/// Strict framing, no chunked request decoding. Header limit includes CRLFCRLF.
struct GatewayHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    var body: Data
    let length: Int
    static let headerLimit = 64 * 1024
    static let bodyLimit = 64 * 1024 * 1024

    static func head(_ data: Data) throws -> Self {
        guard data.count <= headerLimit else { throw GatewayFailure(431, "Request headers too large") }
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n") else {
            throw GatewayFailure(400, "Invalid HTTP headers")
        }
        let lines = String(decoding: data.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(request[2])),
              ["GET", "POST"].contains(String(request[0])), request[1].hasPrefix("/") else {
            throw GatewayFailure(400, "Invalid request line")
        }
        var headers: [String: String] = [:]
        var lengths: [Int] = []
        let tokens = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw GatewayFailure(400, "Invalid header") }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ tokens.contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else {
                throw GatewayFailure(400, "Invalid header characters")
            }
            if name == "content-length" {
                for raw in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let digits = raw.trimmingCharacters(in: .whitespaces)
                    guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(digits) else {
                        throw GatewayFailure(400, "Invalid Content-Length")
                    }
                    lengths.append(length)
                }
            }
            if name == "host", headers[name] != nil { throw GatewayFailure(400, "Duplicate Host") }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        guard headers["transfer-encoding"] == nil else { throw GatewayFailure(400, "Transfer-Encoding requests are unsupported") }
        guard Set(lengths).count <= 1 else { throw GatewayFailure(400, "Conflicting Content-Length") }
        if request[2] == "HTTP/1.1", headers["host"]?.isEmpty != false { throw GatewayFailure(400, "Host required") }
        if headers["expect"] != nil { throw GatewayFailure(417, "Expect is unsupported") }
        if request[0] == "POST", lengths.isEmpty { throw GatewayFailure(411, "Content-Length required") }
        let length = lengths.first ?? 0
        guard length <= bodyLimit else { throw GatewayFailure(413, "Request body too large") }
        return Self(method: String(request[0]), path: String(request[1]), headers: headers, body: Data(), length: length)
    }
}

private final class GatewayStartOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func finish(_ error: Error?, semaphore: DispatchSemaphore) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        failure = error
        semaphore.signal()
    }
}

/// Reject every redirect, even loopback ones: upstream targets are fixed and
/// credentials on the OpenAI route must never escape through Location.
final class GatewayNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class GatewayPeer: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private weak var gateway: UnifiedGateway?
    private let queue: DispatchQueue
    private var buffer = Data()
    private var request: GatewayHTTPRequest?
    private var work: Task<Void, Never>?
    private var upstream: URLSessionTask?
    private var closed = false
    private var headersSent = false // forwarding-task owned
    private var deadline: DispatchWorkItem?

    init(connection: NWConnection, gateway: UnifiedGateway, queue: DispatchQueue) {
        self.connection = connection; self.gateway = gateway; self.queue = queue
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        deadline = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                if self.work != nil { self.close(); return } // never process a second request
                self.buffer.append(data)
                do {
                    if self.request == nil {
                        if let boundary = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                            self.request = try GatewayHTTPRequest.head(Data(self.buffer[..<boundary.upperBound]))
                            self.buffer.removeSubrange(..<boundary.upperBound)
                        } else if self.buffer.count > GatewayHTTPRequest.headerLimit { throw GatewayFailure(431, "Request headers too large") }
                    }
                    if var request = self.request {
                        guard self.buffer.count <= request.length else { throw GatewayFailure(400, "Excess request bytes") }
                        if self.buffer.count == request.length {
                            request.body = self.buffer
                            self.buffer = Data()
                            self.deadline?.cancel()
                            guard let gateway = self.gateway else { self.close(); return }
                            self.work = Task.detached(priority: .utility) { await gateway.handle(request, peer: self) }
                        }
                    }
                } catch {
                    self.deadline?.cancel()
                    let failure = error as? GatewayFailure ?? GatewayFailure(400, "Invalid request")
                    self.work = Task.detached { [self] in
                        try? await self.json(["error": ["message": failure.message]], status: failure.status)
                        await self.finish()
                    }
                    return
                }
            }
            if ended || error != nil { self.close() } else { self.receive() } // detect disconnect during streaming
        }
    }
    func close() { // queue only
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        upstream?.cancel()
        upstream = nil
        work?.cancel()
        work = nil
        connection.cancel()
        gateway?.remove(id)
    }
    func track(_ task: URLSessionTask) {
        queue.async { [self] in
            if closed { task.cancel() } else { upstream = task }
        }
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func json(_ object: [String: Any], status: Int = 200) async throws {
        try await jsonData(JSONSerialization.data(withJSONObject: object), status: status)
    }
    func jsonData(_ data: Data, status: Int = 200) async throws {
        guard !headersSent else { return }
        headersSent = true
        try await send(Data("HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8))
        try await send(data)
    }
    func responseHead(_ response: HTTPURLResponse, allowCredentials: Bool) async throws {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields { headers[String(describing: name).lowercased()] = String(describing: value) }
        headers = UnifiedGateway.filteredHeaders(headers, allowCredentials: allowCredentials, response: true)
        var text = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        headersSent = true
        try await send(Data(text.utf8))
    }
    func finish() async {
        // Send a FIN after all contentProcessed callbacks, then release the peer.
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        queue.async { [self] in close() }
    }
}

struct GatewayRequestTelemetry: Codable, Sendable {
    let id: UUID
    let path: String
    let model: String?
    var upstreamModel: String?
    let source: String
    var phase = "forwarding"
    var startedAt = Date()
    var finishedAt: Date?
    var status: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var callKey: String { "\(source)|\(upstreamModel ?? "")" }
}

private actor GatewayTelemetry {
    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RailRouter/gateway-telemetry.json")
    private let file: URL?
    private var records: [GatewayRequestTelemetry] = []
    /// Appels reçus par modèle (`callKey`) depuis le démarrage du gateway ; `records` n'en garde que 100.
    private var calls: [String: Int] = [:]
    init(file: URL?) { self.file = file }
    func snapshot() -> [GatewayRequestTelemetry] { records }
    func json() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        struct Envelope: Encodable { let requests: [GatewayRequestTelemetry]; let calls: [String: Int] }
        return (try? encoder.encode(Envelope(requests: records, calls: calls))) ?? Data("{\"requests\":[]}".utf8)
    }
    func begin(_ record: GatewayRequestTelemetry) {
        calls[record.callKey, default: 0] += 1
        update(record)
    }
    func update(_ record: GatewayRequestTelemetry) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        if records.count > 100 { records.removeFirst(records.count - 100) }
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json().write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* No credential-bearing request/error logging. GET /telemetry remains available. */ }
    }
}

/// Transient bounded JSON/SSE parsing. Stores measured usage only; counts are
/// snapshots, never summed across SSE events or estimated from strings.
struct GatewayUsageParser {
    let sse: Bool
    private var buffer = Data()
    private var event = Data()
    private var dropping = false
    private var droppingEvent = false
    private(set) var promptTokens: Int?
    private(set) var completionTokens: Int?
    private(set) var reportedModel: String?
    mutating func ingest(_ byte: UInt8) {
        let limit = sse ? 1024 * 1024 : GatewayHTTPRequest.bodyLimit
        if sse && byte == 10 {
            if !dropping { line() } else { droppingEvent = true }
            buffer.removeAll(keepingCapacity: false)
            dropping = false
        } else if !dropping {
            if buffer.count < limit { buffer.append(byte) }
            else { buffer.removeAll(); dropping = true }
        }
    }
    private mutating func line() {
        if buffer.last == 13 { buffer.removeLast() }
        if buffer.isEmpty {
            if !droppingEvent { parse(event) }
            event.removeAll(keepingCapacity: false)
            droppingEvent = false
        } else if buffer.starts(with: Data("data:".utf8)), !droppingEvent {
            var value = buffer.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            if event.count + value.count + 1 > 1024 * 1024 { event.removeAll(); droppingEvent = true }
            else { if !event.isEmpty { event.append(10) }; event.append(contentsOf: value) }
        }
    }
    mutating func finish() {
        if sse {
            if !buffer.isEmpty && !dropping { line() }
            if !droppingEvent { parse(event) }
        } else if !dropping { parse(buffer) }
        buffer.removeAll(); event.removeAll()
    }
    private mutating func parse(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let response = object["response"] as? [String: Any]
        if let model = (object["model"] ?? response?["model"]) as? String, !model.isEmpty, model.utf8.count <= 1024 { reportedModel = model }
        guard let usage = (object["usage"] ?? response?["usage"]) as? [String: Any] else { return }
        func count(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < Double(Int.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            return number.intValue
        }
        if let value = count(usage["prompt_tokens"] ?? usage["input_tokens"]) { promptTokens = value }
        if let value = count(usage["completion_tokens"] ?? usage["output_tokens"]) { completionTokens = value }
    }
}

/// Only instantiated for an actual MLX POST, never health/model discovery.
private final class GatewayMLXActivity: @unchecked Sendable {
    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/mlx-qwen38/8090.dernier")
    private let file: URL?
    private var heartbeat: Task<Void, Never>?
    init(file: URL?) {
        self.file = file
        Self.touch(file)
        heartbeat = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                if !Task.isCancelled { Self.touch(file) }
            }
        }
    }
    func stop() { heartbeat?.cancel(); heartbeat = nil; Self.touch(file) }
    deinit { stop() }
    private static func touch(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }
}

private final class GatewayMetadataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: GatewayCatalog?
    private var expires = Date.distantPast
    func get() -> GatewayCatalog? { lock.lock(); defer { lock.unlock() }; return Date() < expires ? catalog : nil }
    func put(_ catalog: GatewayCatalog) { lock.lock(); defer { lock.unlock() }; self.catalog = catalog; expires = Date().addingTimeInterval(5) }
}

struct GatewayResident: Sendable {
    let source: String
    let model: String
    var suggestion: String { source == "mlx" ? "mlx/" + model : model }
}

struct GatewayResidency: Sendable {
    var models: [GatewayResident] = []
    let mlxLoadedModel: String?
    init(ollama: [String: Any] = [:], studio: [String: Any] = [:], mlx: [String: Any] = [:]) {
        for item in ollama["models"] as? [[String: Any]] ?? [] {
            if let id = (item["name"] ?? item["model"]) as? String { models.append(GatewayResident(source: "ollama", model: id)) }
        }
        for item in studio["data"] as? [[String: Any]] ?? [] where item["state"] as? String == "loaded" {
            if let id = item["id"] as? String { models.append(GatewayResident(source: "lmStudio", model: id)) }
        }
        mlxLoadedModel = mlx["loaded_model"] as? String
        if let id = mlxLoadedModel { models.append(GatewayResident(source: "mlx", model: id)) }
        // The current server may retain additional models in its cache.
        if let loaded = mlx["loaded_models"] as? [String: Any] {
            for value in loaded.values {
                if let entry = value as? [String: Any], let id = entry["model"] as? String, id != mlxLoadedModel {
                    models.append(GatewayResident(source: "mlx", model: id))
                }
            }
        }
    }
    func validate(source: String, model: String, inflight: [GatewayResident] = []) throws {
        for resident in models + inflight where resident.source != source && ModelName.sameModel(resident.model, model) {
            throw GatewayFailure(409, "This model family is already resident in \(resident.source). Use \(resident.suggestion) on its existing endpoint; no model was loaded or unloaded.")
        }
        if source == "mlx", mlxLoadedModel != model {
            throw GatewayFailure(409, "MLX only reuses its current loaded_model. Use \(mlxLoadedModel.map { "mlx/" + $0 } ?? "/v1/chat/completions with an already loaded model"); the gateway will not load other weights.")
        }
    }
}

/// Serial reservations prevent concurrent gateway requests from racing each
/// other into a cross-engine load. Other clients remain outside this gateway.
private actor GatewayResidencyGate {
    private var inflight: [UUID: GatewayResident] = [:]
    func acquire(id: UUID, source: String, model: String, residency: GatewayResidency) throws {
        try residency.validate(source: source, model: model, inflight: Array(inflight.values))
        inflight[id] = GatewayResident(source: source, model: model)
    }
    func release(_ id: UUID) { inflight[id] = nil }
}

/// Fixed, installed libzstd ABI, no shell/process/temp files. Both the compressed
/// HTTP body and decompressed JSON have a 64 MiB ceiling; output is streamed.
enum GatewayZstd {
    static func decode(_ data: Data, encoding: String?, limit: Int = GatewayHTTPRequest.bodyLimit) throws -> Data {
        guard let encoding, encoding.lowercased() != "identity" else { return data }
        guard encoding.lowercased() == "zstd" else { throw GatewayFailure(415, "Unsupported Content-Encoding") }
        let library = ["/opt/homebrew/lib/libzstd.dylib", "/usr/local/lib/libzstd.dylib"]
            .lazy.compactMap { (path: String) in path.withCString { dlopen($0, RTLD_NOW | RTLD_LOCAL) } }.first
        guard let library else { throw GatewayFailure(415, "zstd decoder is not installed") }
        defer { dlclose(library) }
        typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
        typealias Free = @convention(c) (UnsafeMutableRawPointer) -> Int
        typealias Step = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
        typealias IsError = @convention(c) (Int) -> UInt32
        guard let c = dlsym(library, "ZSTD_createDStream"), let f = dlsym(library, "ZSTD_freeDStream"),
              let d = dlsym(library, "ZSTD_decompressStream"), let e = dlsym(library, "ZSTD_isError") else {
            throw GatewayFailure(415, "zstd decoder API unavailable")
        }
        let create = unsafeBitCast(c, to: Create.self), free = unsafeBitCast(f, to: Free.self)
        let step = unsafeBitCast(d, to: Step.self), isError = unsafeBitCast(e, to: IsError.self)
        guard let stream = create() else { throw GatewayFailure(503, "zstd decoder unavailable") }
        defer { _ = free(stream) }
        // zstd.h: { void *src/dst; size_t size; size_t pos; }. Allocate the C
        // layout explicitly rather than rely on the layout of a Swift struct.
        let stride = MemoryLayout<UInt>.stride
        let input = UnsafeMutableRawPointer.allocate(byteCount: stride * 3, alignment: stride)
        let output = UnsafeMutableRawPointer.allocate(byteCount: stride * 3, alignment: stride)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: stride)
        defer { input.deallocate(); output.deallocate(); scratch.deallocate() }
        return try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress, !data.isEmpty else { throw GatewayFailure(400, "Invalid zstd body") }
            input.storeBytes(of: UInt(bitPattern: address), as: UInt.self)
            input.storeBytes(of: data.count, toByteOffset: stride, as: Int.self)
            input.storeBytes(of: 0, toByteOffset: stride * 2, as: Int.self)
            output.storeBytes(of: UInt(bitPattern: scratch), as: UInt.self)
            output.storeBytes(of: 64 * 1024, toByteOffset: stride, as: Int.self)
            var decoded = Data()
            while true {
                let before = input.load(fromByteOffset: stride * 2, as: Int.self)
                output.storeBytes(of: 0, toByteOffset: stride * 2, as: Int.self)
                let remaining = step(stream, output, input)
                guard isError(remaining) == 0 else { throw GatewayFailure(400, "Invalid zstd body") }
                let produced = output.load(fromByteOffset: stride * 2, as: Int.self)
                guard decoded.count + produced <= limit else { throw GatewayFailure(413, "Decompressed request body too large") }
                decoded.append(scratch.assumingMemoryBound(to: UInt8.self), count: produced)
                let consumed = input.load(fromByteOffset: stride * 2, as: Int.self)
                if remaining == 0 && consumed == data.count { return decoded }
                guard produced > 0 || consumed > before else { throw GatewayFailure(400, "Truncated zstd body") }
            }
        }
    }
}


/// OpenRouter access: key read at request time (never logged), free-model list from the public API.
enum GatewayOpenRouter {
    static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment,
                       authFile: URL = FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent(".local/share/opencode/auth.json"),
                       keyFile: URL = CloudProviders.keyFile) -> String? {
        if let key = CloudProviders.apiKey(for: "openrouter", environment: environment, file: keyFile) { return key }
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["openrouter"] as? [String: Any],
              let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// `{"data":[{"id":…}]}` restricted to free models (`:free`, `openrouter/free`).
    static func freeIDs(_ payload: [String: Any]) -> [String: Any] {
        let items = (payload["data"] as? [[String: Any]] ?? []).compactMap { item -> [String: Any]? in
            guard let id = item["id"] as? String, id.hasSuffix(":free") || id == "openrouter/free" else { return nil }
            return ["id": id, "owned_by": "openrouter"]
        }
        return ["data": items]
    }

    static func freeCatalog(session: URLSession) async -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.timeoutInterval = 4
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request, delegate: GatewayNoRedirect()),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return freeIDs(json)
    }
}

/// Alibaba Cloud Model Studio (DashScope), OpenAI-compatible mode. Key from `DASHSCOPE_API_KEY`, read at request time, never logged.
enum GatewayAlibaba {
    /// Workspace-specific host (`…/compatible-mode`, without `/v1`: the request path already starts with it); override with `DASHSCOPE_BASE_URL`.
    static func baseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let custom = environment["DASHSCOPE_BASE_URL"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        let base = custom.flatMap { $0.isEmpty ? nil : $0 } ?? "https://ws-6yq2ck8vtygm4jna.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
        return base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
    }

    static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment, keyFile: URL = CloudProviders.keyFile) -> String? {
        CloudProviders.apiKey(for: "alibaba", environment: environment, file: keyFile)
    }

    /// `data` of `GET …/v1/models` (id, created, owned_by only); empty without a key or on any failure.
    static func entries(session: URLSession) async -> [[String: Any]] {
        guard let key = apiKey(), let url = URL(string: baseURL() + "/v1/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request, delegate: GatewayNoRedirect()),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["data"] as? [[String: Any]] ?? []
    }

    static func catalog(session: URLSession) async -> [String: Any] {
        ["data": await entries(session: session).compactMap { item -> [String: Any]? in
            guard let id = item["id"] as? String else { return nil }
            return ["id": id, "created": item["created"] as Any, "owned_by": "alibaba"]
        }]
    }
}
