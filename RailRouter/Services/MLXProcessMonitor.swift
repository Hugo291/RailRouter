import Foundation
import Darwin

/// Détecte les processus MLX directs (chargement de .safetensors hors LM Studio/Ollama).
/// C'est LE composant critique pour éviter le double chargement.
///
/// Deux sources :
///  1. `ps` : processus dont l'exécutable est Python (avec preuve MLX dans les args)
///     ou un binaire `mlx*` — via `ProcessScanner`.
///  2. `lsof` : fichiers `.safetensors` ouverts — en **excluant** les processus
///     appartenant aux apps Ollama / LM Studio (leurs backends internes ouvriraient
///     sinon des instances fantômes qui dupliqueraient l'état déjà rapporté par
///     l'API de chaque moteur).
///  3. `lsof` : processus qui ont chargé `libmlx.dylib` sans rien montrer d'autre
///     (script Python qui importe mlx et charge le modèle lui-même).
/// RAM : empreinte physique (mémoire GPU comprise), pas la RSS de `ps`.
actor MLXProcessMonitor {

    /// Marqueurs de commande qui identifient un backend interne d'un moteur
    /// déjà couvert (Ollama / LM Studio) — à exclure du "MLX direct".
    /// Pas `/.lmstudio/` entier : un serveur MLX direct peut charger un modèle rangé
    /// dans `~/.lmstudio/models/` (serveur Clef sur 8091, 09/10/2026).
    private static let engineMarkers = [
        "/Ollama.app/", "ollama runner",
        "/LM Studio.app/", "/.lmstudio/.internal/", "/.lmstudio/bin/",
        "/.lmstudio/extensions/", "/.lmstudio/llmster/"
    ]

    static func isEngineBackend(_ commandLine: String) -> Bool {
        engineMarkers.contains { commandLine.contains($0) }
    }

    /// Scanne le système et renvoie les instances MLX directes.
    func scan() async -> [ModelInstance] {
        let all = ProcessScanner.allProcesses()

        // PIDs appartenant à un moteur couvert → exclus du "direct".
        let enginePids = Set(all.filter { Self.isEngineBackend($0.commandLine) }.map { $0.pid })

        var instances: [ModelInstance] = []

        // 1. Processus MLX avérés via la ligne de commande.
        for proc in ProcessScanner.scanMLXProcesses(in: all) where !enginePids.contains(proc.pid) {
            let modelName = Self.argument("--model", in: proc.commandLine) ?? Self.modelName(from: proc.commandLine)
            var instance = ModelInstance(
                modelName: modelName,
                engine: .mlxDirect,
                ram_MB: ProcessScanner.footprintMB(pid: proc.pid) ?? proc.ramUsage_MB,
                pid: proc.pid,
                loadedAt: Date(),
                status: .active
            )
            instance.endpointURL = Self.serverEndpoint(from: proc.commandLine)
            instance.draftModelName = Self.argument("--draft-model", in: proc.commandLine)
            if let endpoint = instance.endpointURL {
                instance = await enrich(instance, endpoint: endpoint, expectedModel: Self.argument("--model", in: proc.commandLine))
            }
            instances.append(instance)
        }

        // 2. Fichiers .safetensors ouverts (lsof) — hors moteurs, hors doublons.
        let lsof = ProcessScanner.lsofMLX()
        for entry in lsof.safetensors {
            guard !enginePids.contains(entry.pid) else { continue }
            if instances.contains(where: { $0.pid == entry.pid }) { continue }

            let modelName = entry.filePath
                .components(separatedBy: "/").last?
                .replacingOccurrences(of: ".safetensors", with: "") ?? "inconnu"

            instances.append(ModelInstance(
                modelName: modelName,
                engine: .mlxDirect,
                ram_MB: ProcessScanner.footprintMB(pid: entry.pid) ?? 0,
                pid: entry.pid,
                loadedAt: Date(),
                status: .active
            ))
        }

        // 3. libmlx.dylib chargée (lsof) — hors moteurs, hors doublons.
        let commands = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for pid in lsof.mlxPIDs.sorted() where !enginePids.contains(pid) && !instances.contains(where: { $0.pid == pid }) {
            instances.append(ModelInstance(
                modelName: Self.modelName(from: commands[pid]?.commandLine ?? ""),
                engine: .mlxDirect,
                ram_MB: ProcessScanner.footprintMB(pid: pid) ?? commands[pid]?.ramUsage_MB ?? 0,
                pid: pid,
                loadedAt: Date(),
                status: .active
            ))
        }

        return instances
    }

    private func enrich(_ instance: ModelInstance, endpoint: URL, expectedModel: String?) async -> ModelInstance {
        var instance = instance
        var request = URLRequest(url: endpoint.appendingPathComponent("metrics"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return instance }
        Self.applyMetrics(data, to: &instance, expectedModel: expectedModel)
        return instance
    }

    static func applyMetrics(_ data: Data, to instance: inout ModelInstance, expectedModel: String?) {
        struct Metrics: Decodable {
            let latest: Measurement?
            let server: Server?
            struct Server: Decodable { let loaded_model: String?; let effective_context_limit: Int? }
            struct Measurement: Decodable {
                let model: String
                let timestamp_unix: Double
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let decode_tok_s: Double?
            }
        }
        guard let metrics = try? JSONDecoder().decode(Metrics.self, from: data),
              let expectedModel, metrics.server?.loaded_model == expectedModel else { return }
        instance.modelName = expectedModel
        instance.displayName = (expectedModel as NSString).lastPathComponent
        instance.contextLength = metrics.server?.effective_context_limit
        if let stat = metrics.latest, stat.model == expectedModel,
           stat.timestamp_unix.isFinite, stat.timestamp_unix > 0 {
            instance.lastPrediction = PredictionTelemetry(
                completedAt: Date(timeIntervalSince1970: stat.timestamp_unix),
                promptTokens: stat.prompt_tokens.flatMap { $0 >= 0 ? $0 : nil },
                generatedTokens: stat.completion_tokens.flatMap { $0 >= 0 ? $0 : nil },
                tokensPerSecond: stat.decode_tok_s.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                source: "MLX · /v1/metrics")
        }
    }

    static func argument(_ flag: String, in command: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: flag) + "(?:=|\\s+)(?:\"([^\"]+)\"|'([^']+)'|(\\S+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: command) { return String(command[range]) }
        }
        return nil
    }

    static func serverEndpoint(from command: String) -> URL? {
        guard command.contains("mlx_vlm.server") || command.contains("mlx_lm.server"),
              let text = argument("--port", in: command), let port = UInt16(text), port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/v1")
    }

    /// Termination d'un processus MLX direct (éjection).
    func kill(pid: Int) async {
        await withCheckedContinuation { cont in
            Task.detached {
                _ = Darwin.kill(pid_t(pid), SIGTERM)
                cont.resume()
            }
        }
    }

    /// Extrait le nom du modèle depuis la ligne de commande (internal : tests unitaires).
    static func modelName(from commandLine: String) -> String {
        // Nom servi (clef_mlx serve --name clef) : c'est le modèle demandé à l'endpoint RailRouter.
        if let name = argument("--name", in: commandLine) { return name }
        if let model = argument("--model", in: commandLine) {
            return (model as NSString).lastPathComponent
        }
        // Le 1er jeton est l'exécutable (…/bin/python) : jamais un nom de modèle.
        let args = commandLine.split(separator: " ").dropFirst().map(String.init)
        if let path = args.first(where: { $0.hasSuffix(".safetensors") }) {
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        // Script qui charge le modèle lui-même : `-m module` ou `script.py`.
        if let index = args.firstIndex(of: "-m"), index + 1 < args.count { return args[index + 1] }
        if let script = args.first(where: { $0.hasSuffix(".py") }) { return (script as NSString).lastPathComponent }
        if let path = args.first(where: { $0.contains("/") }) { return (path as NSString).lastPathComponent }
        return "MLX (inconnu)"
    }
}

// ── TYPES DE RÉPONSE DU SCAN ──

struct MLXProcessInfo {
    let pid: Int
    let commandLine: String
    let ramUsage_MB: Double
}

struct SafetensorsEntry {
    let pid: Int
    let filePath: String
}
