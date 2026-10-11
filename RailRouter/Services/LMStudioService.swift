import Foundation

/// Service LM Studio.
/// - **`lms` CLI** (canal RPC riche) : bibliothèque avec tailles (`ls --json`),
///   modèles chargés avec statut/TTL/processing (`ps --json`), éjection.
/// - **HTTP OpenAI-compatible** (`:1234`) : check connexion, chat/génération,
///   et repli pour l'état chargé (`/api/v0/models` → champ `state`).
actor LMStudioService {

    private let baseURL = AppSettings.lmStudioBaseURL
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Connexion (check HTTP rapide)

    func checkConnection() async -> (Bool, String?) {
        do {
            let (data, response) = try await session.data(from: baseURL.appendingPathComponent("v1/models"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return (false, nil) }
            _ = data
            return (true, "0.4.x")
        } catch {
            return (false, nil)
        }
    }

    // MARK: - Schéma JSON du CLI `lms` (`ps` et `ls` partagent ce schéma)

    struct LMSModel: Decodable {
        let type: String?
        let format: String?
        let displayName: String?
        let identifier: String?
        let modelKey: String?
        let indexedModelIdentifier: String?
        let publisher: String?
        let path: String?
        let sizeBytes: Int64?
        let ttlMs: Double?
        let lastUsedTime: Double?     // epoch ms (ps)
        let vision: Bool?
        let trainedForToolUse: Bool?
        let quantization: Quant?
        let paramsString: String?
        let maxContextLength: Int?
        let contextLength: Int?
        let status: String?           // idle | processingPrompt | generating | … (ps)
        let processedPromptTokenCount: Int?
        let totalPromptTokenCount: Int?
        let deviceIdentifier: String?
        struct Quant: Decodable { let name: String?; let bits: Int? }
    }

    /// `lms ps --json` → instances riches (internal : tests unitaires).
    static func decodeInstances(from data: Data) -> [ModelInstance] {
        guard let arr = try? JSONDecoder().decode([LMSModel].self, from: data) else { return [] }
        return arr.map { m in
            var percent: Double? = nil
            let state = ProcessState(rawValue: m.status ?? "") ?? .unknown
            // Current lms exposes only status/queued. Accept counts only if a backend
            // actually supplies a valid pair for the current prompt-processing phase.
            if state == .processingPrompt, let t = m.totalPromptTokenCount, t > 0,
               let p = m.processedPromptTokenCount, p >= 0, p <= t {
                percent = Double(p) / Double(t) * 100
            }
            let lastUsed = m.lastUsedTime.map { Date(timeIntervalSince1970: $0 / 1000) }
            return ModelInstance(
                modelName: m.identifier ?? m.modelKey ?? m.displayName ?? "inconnu",
                engine: .lmStudio,
                ram_MB: Double(m.sizeBytes ?? 0) / (1024 * 1024),
                pid: nil,
                loadedAt: Date(),
                status: .active,
                displayName: m.displayName,
                typeLabel: m.type,
                sizeBytes: m.sizeBytes,
                ttlMs: m.ttlMs,
                lastUsedTime: lastUsed,
                processState: state,
                processingPromptPercent: percent,
                vision: m.vision,
                tools: m.trainedForToolUse,
                quantization: m.quantization?.name,
                params: m.paramsString,
                contextLength: m.contextLength ?? m.maxContextLength,
                processedPromptTokens: percent == nil ? nil : m.processedPromptTokenCount,
                totalPromptTokens: percent == nil ? nil : m.totalPromptTokenCount,
                runtimeDeviceIdentifier: m.deviceIdentifier
            )
        }
    }

    /// `lms ls --json` → bibliothèque (avec tailles disque) (internal : tests).
    static func decodeLibrary(from data: Data, modelsRoot: URL? = nil, modelIndexURL: URL? = nil) -> [LLMModel] {
        guard let arr = try? JSONDecoder().decode([LMSModel].self, from: data) else { return [] }
        let root = modelsRoot ?? modelRoot()
        let indexURL = modelIndexURL ?? (modelsRoot == nil ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/.internal/model-index-cache.json") : nil)
        let indexedModels = indexURL.flatMap(readModelIndex)?.models ?? []
        return arr.compactMap { m in
            let id = m.modelKey ?? m.identifier ?? m.displayName
            guard let id else { return nil }
            var caps = [String]()
            if m.type == "vlm" || m.vision == true { caps.append("vision") }
            if m.trainedForToolUse == true { caps.append("tools") }
            if m.type == "embedding" || m.type == "embeddings" { caps.append("embedding") }
            var files = m.path.flatMap { $0.isEmpty ? nil : modelFiles(at: resolveModelPath($0, root: root)) } ?? []
            if files.isEmpty {
                // Hub aliases and bundled embeddings are not located under downloadsFolder.
                // Trust an explicit index mapping, never infer a repository from its display name.
                let identifier = m.indexedModelIdentifier ?? id
                if let entry = indexedModels.first(where: { $0.indexedModelIdentifier == identifier }),
                   let path = entry.concreteModelDirAbsolutePath ?? entry.containingDirAbsolutePath {
                    let directory = URL(fileURLWithPath: path)
                    if let relative = m.path, relative.lowercased().hasSuffix(".gguf") {
                        files = modelFiles(at: directory.appendingPathComponent(URL(fileURLWithPath: relative).lastPathComponent))
                    } else { files = modelFiles(at: directory) }
                }
            }
            let hasReportedParameters = LLMModel.parameterValue(m.paramsString) != nil
            let count = hasReportedParameters ? nil : parameterCount(in: files)
            var model = LLMModel(
                id: id,
                name: m.displayName ?? id,
                parameters: hasReportedParameters ? m.paramsString : count.map(parameterLabel),
                quantization: m.quantization?.name,
                sizeBytes: Int64(m.sizeBytes ?? 0),
                capabilities: caps,
                modified: files.compactMap {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                }.max(),
                source: .lmStudio
            )
            model.reportedParameterCount = count.map { Double($0) }
            return model
        }
    }

    private struct ModelIndex: Decodable {
        let models: [Entry]
        struct Entry: Decodable {
            let indexedModelIdentifier: String?
            let concreteModelDirAbsolutePath: String?
            let containingDirAbsolutePath: String?
        }
    }

    private static func readModelIndex(_ url: URL) -> ModelIndex? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024 * 1024 + 1), data.count <= 16 * 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(ModelIndex.self, from: data)
    }

    /// Decode only the model directory setting; never inspect credential files.
    static func modelRoot(settingsURL: URL? = nil,
                          homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        struct Settings: Decodable { let downloadsFolder: String? }
        let fallback = homeDirectory.appendingPathComponent(".lmstudio/models", isDirectory: true)
        let url = settingsURL ?? homeDirectory.appendingPathComponent(".lmstudio/settings.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return fallback }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let settings = try? JSONDecoder().decode(Settings.self, from: data),
              let path = settings.downloadsFolder, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return resolveModelPath(path, root: homeDirectory, homeDirectory: homeDirectory)
    }

    static func resolveModelPath(_ path: String, root: URL,
                                 homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    private static func modelFiles(at url: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        func isModelFile(_ file: URL) -> Bool {
            let name = file.lastPathComponent.lowercased()
            if file.pathExtension.lowercased() == "json" {
                return name.hasSuffix("config.json") || name.hasSuffix(".index.json")
                    || name == "params.json" || name == "manifest.json"
            }
            return ["gguf", "safetensors", "bin", "pt", "pth", "npz"].contains(file.pathExtension.lowercased())
        }
        guard let values = try? url.resourceValues(forKeys: keys) else { return [] }
        if values.isRegularFile == true { return isModelFile(url) ? [url] : [] }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var files = [URL]()
        for case let file as URL in enumerator {
            let name = file.lastPathComponent.lowercased()
            let values = try? file.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if ["cache", "caches", "download", "downloads", "tmp", "temp"].contains(name)
                    || name.hasSuffix(".cache") || name.hasSuffix(".tmp") {
                    enumerator.skipDescendants()
                }
            } else if values?.isRegularFile == true, isModelFile(file) {
                files.append(file)
            }
        }
        return files
    }

    private static func parameterCount(in files: [URL]) -> UInt64? {
        let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
        // Multiple files may be alternative quantizations or shards: do not guess or double count.
        guard ggufs.count == 1, let count = try? ggufParameterCount(at: ggufs[0]), count > 0 else { return nil }
        return count
    }

    private static func parameterLabel(_ count: UInt64) -> String {
        guard count >= 1_000 else { return String(count) }
        let scale: UInt64 = count >= 1_000_000_000 ? 1_000_000_000 : count >= 1_000_000 ? 1_000_000 : 1_000
        let suffix = scale == 1_000_000_000 ? "B" : scale == 1_000_000 ? "M" : "K"
        var value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(count) / Double(scale))
        while value.last == "0" { value.removeLast() }
        if value.last == "." { value.removeLast() }
        return value + suffix
    }

    private enum GGUFError: Error { case invalidHeader }

    /// Bounded, buffered header reader. Tensor payloads are never loaded into memory.
    private final class GGUFHeader {
        let handle: FileHandle
        let limit: UInt64
        var offset: UInt64 = 0
        var buffer = Data()
        var bufferOffset: UInt64 = 0

        init(url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            do {
                limit = min(try handle.seekToEnd(), 16 * 1024 * 1024)
            } catch {
                try? handle.close()
                throw error
            }
        }

        deinit { try? handle.close() }

        func bytes(_ count: UInt64) throws -> Data {
            guard offset <= limit, count <= limit - offset, count <= 65_536 else { throw GGUFError.invalidHeader }
            if offset < bufferOffset || offset + count > bufferOffset + UInt64(buffer.count) {
                try handle.seek(toOffset: offset)
                buffer = try handle.read(upToCount: Int(min(limit - offset, max(count, 4096)))) ?? Data()
                bufferOffset = offset
            }
            let start = Int(offset - bufferOffset)
            guard start + Int(count) <= buffer.count else { throw GGUFError.invalidHeader }
            offset += count
            return buffer.subdata(in: start..<(start + Int(count)))
        }

        func uint(_ width: UInt64) throws -> UInt64 {
            let data = try bytes(width)
            return data.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        }

        func skip(_ count: UInt64) throws {
            guard offset <= limit, count <= limit - offset else { throw GGUFError.invalidHeader }
            offset += count
        }

        func string() throws -> String {
            let length = try uint(8)
            guard let value = String(data: try bytes(length), encoding: .utf8) else { throw GGUFError.invalidHeader }
            return value
        }

        func skipValue(_ type: UInt64, depth: Int = 0) throws {
            switch type {
            case 0, 1, 7: try skip(1)
            case 2, 3: try skip(2)
            case 4, 5, 6: try skip(4)
            case 10, 11, 12: try skip(8)
            case 8: try skip(uint(8))
            case 9:
                guard depth < 8 else { throw GGUFError.invalidHeader }
                let elementType = try uint(4)
                let count = try uint(8)
                guard count <= 1_000_000 else { throw GGUFError.invalidHeader }
                for _ in 0..<count { try skipValue(elementType, depth: depth + 1) }
            default: throw GGUFError.invalidHeader
            }
        }
    }

    private static func ggufParameterCount(at url: URL) throws -> UInt64 {
        let reader = try GGUFHeader(url: url)
        guard try reader.uint(4) == 0x46554747 else { throw GGUFError.invalidHeader }
        let version = try reader.uint(4)
        guard version == 2 || version == 3 else { throw GGUFError.invalidHeader }
        let tensorCount = try reader.uint(8)
        let metadataCount = try reader.uint(8)
        guard tensorCount <= 100_000, metadataCount <= 100_000 else { throw GGUFError.invalidHeader }
        for _ in 0..<metadataCount {
            let key = try reader.string()
            let type = try reader.uint(4)
            if key == "general.parameter_count", [UInt64(0), 2, 4, 10].contains(type) {
                let width: UInt64 = type == 0 ? 1 : type == 2 ? 2 : type == 4 ? 4 : 8
                let count = try reader.uint(width)
                if count > 0 { return count }
            } else {
                try reader.skipValue(type)
            }
        }
        var total: UInt64 = 0
        for _ in 0..<tensorCount {
            try reader.skip(reader.uint(8)) // tensor name
            let dimensions = try reader.uint(4)
            guard dimensions > 0, dimensions <= 4 else { throw GGUFError.invalidHeader }
            var elements: UInt64 = 1
            for _ in 0..<dimensions {
                let dimension = try reader.uint(8)
                let product = elements.multipliedReportingOverflow(by: dimension)
                guard dimension > 0, !product.overflow else { throw GGUFError.invalidHeader }
                elements = product.partialValue
            }
            try reader.skip(12) // tensor type + payload offset; quantization does not change the count
            let sum = total.addingReportingOverflow(elements)
            guard !sum.overflow else { throw GGUFError.invalidHeader }
            total = sum.partialValue
        }
        return total
    }

    // MARK: - Bibliothèque

    func listModels() async -> [LLMModel] {
        // 1. CLI : le plus riche (tailles, params, vision/tools).
        if let lms = Shell.lmsPathIfRunning(),
           let raw = await Shell.run(lms, ["ls", "--json"]) {
            let models = Self.decodeLibrary(from: raw.data(using: .utf8) ?? Data())
            if !models.isEmpty { return models }
        }
        // 2. Repli HTTP v0.
        return await listModelsHTTP()
    }

    private struct v0Model: Decodable {
        let id: String
        let type: String?
        let publisher: String?
        let quantization: String?
        let state: String?
        let capabilities: [String]?
    }
    private struct v0List: Decodable { let data: [v0Model] }

    private func listModelsHTTP() async -> [LLMModel] {
        do {
            let url = baseURL.appendingPathComponent("api/v0/models")
            let (data, _) = try await session.data(from: url)
            let list = try JSONDecoder().decode(v0List.self, from: data)
            return list.data.map { m in
                var caps = [String]()
                if m.type == "vlm" { caps.append("vision") }
                if m.capabilities?.contains("tool_use") == true { caps.append("tools") }
                return LLMModel(
                    id: m.id,
                    name: m.id,
                    parameters: nil,
                    quantization: m.quantization,
                    sizeBytes: 0,
                    capabilities: caps,
                    modified: nil,
                    source: .lmStudio
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Modèles chargés

    /// Instances chargées, avec statut de traitement, taille, TTL, vision/tools.
    func getLoadedModels() async -> [ModelInstance] {
        // 1. CLI : données complètes (status, %, sizeBytes, ttl…).
        if let lms = Shell.lmsPathIfRunning(),
           let raw = await Shell.run(lms, ["ps", "--json"]) {
            let instances = Self.decodeInstances(from: raw.data(using: .utf8) ?? Data())
            if !instances.isEmpty { return instances }
        }
        // 2. Repli HTTP : `/api/v0/models` expose le champ `state`.
        return await loadedModelsHTTP()
    }

    private func loadedModelsHTTP() async -> [ModelInstance] {
        do {
            let url = baseURL.appendingPathComponent("api/v0/models")
            let (data, _) = try await session.data(from: url)
            let list = try JSONDecoder().decode(v0List.self, from: data)
            return list.data.compactMap { m in
                guard m.state == "loaded" else { return nil }
                return ModelInstance(
                    modelName: m.id,
                    engine: .lmStudio,
                    ram_MB: 0,
                    pid: nil,
                    loadedAt: Date(),
                    status: .active,
                    typeLabel: m.type,
                    vision: m.type == "vlm" ? true : nil,
                    tools: m.capabilities?.contains("tool_use") == true ? true : nil,
                    quantization: m.quantization
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Actions

    /// Éjecte un modèle via le CLI (canal RPC officiel).
    func unloadModel(identifier: String) async throws {
        guard let lms = Shell.lmsPathIfRunning() else { throw LMS.unavailable }
        _ = await Shell.run(lms, ["unload", identifier])
    }

    /// Éjecte TOUS les modèles chargés.
    func unloadAll() async throws {
        guard let lms = Shell.lmsPathIfRunning() else { throw LMS.unavailable }
        _ = await Shell.run(lms, ["unload", "--all"])
    }

    func loadModel(id: String) async throws {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": id,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: req)
    }

    func generate(prompt: String, model: String, maxTokens: Int = 512) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw LMS.badResponse }
        return content
    }

    func chat(messages: [ChatMessage], model: String) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let msgArray: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        let body: [String: Any] = ["model": model, "messages": msgArray, "stream": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw LMS.badResponse }
        return content
    }

    enum LMS: Error, LocalizedError {
        case unavailable, badResponse
        var errorDescription: String? {
            switch self {
            case .unavailable: return L("CLI « lms » introuvable (LM Studio non installé ?)")
            case .badResponse: return L("Réponse inattendue de LM Studio")
            }
        }
    }
}
