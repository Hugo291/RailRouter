import Foundation

/// État d'inférence d'une instance (miroir de `modelProcessingStateSchema` de LM Studio).
enum ProcessState: String {
    case idle = "idle"
    case processingPrompt = "processingPrompt"
    case generating = "generating"
    case computingEmbedding = "computingEmbedding"
    case unknown = "unknown"

    var label: String {
        switch self {
        case .idle: return "IDLE"
        case .processingPrompt: return "PROCESSING PROMPT"
        case .generating: return "GENERATING"
        case .computingEmbedding: return "COMPUTING EMBEDDING"
        case .unknown: return "—"
        }
    }
    var isBusy: Bool { self != .idle && self != .unknown }
}

/// Une instance active d'un modèle (chargée en mémoire)
struct ModelInstance: Identifiable {
    /// Runtime identifiers (not family names) survive repeated polling. MLX uses its PID.
    var id: String {
        [engine.rawValue, runtimeDeviceIdentifier ?? "", modelName, pid.map(String.init) ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
    var modelName: String
    let engine: LLMModel.ModelSource
    var ram_MB: Double
    let pid: Int?
    let loadedAt: Date
    let status: Status

    // ── Données riches (surtout via `lms ps --json`) ──
    var displayName: String? = nil
    var typeLabel: String? = nil          // "llm" | "vlm" | "embedding"
    var sizeBytes: Int64? = nil
    var ttlMs: Double? = nil
    var lastUsedTime: Date? = nil
    var processState: ProcessState = .unknown
    var processingPromptPercent: Double? = nil   // 0…100
    var vision: Bool? = nil
    var tools: Bool? = nil
    var quantization: String? = nil
    var params: String? = nil
    var contextLength: Int? = nil
    var processedPromptTokens: Int? = nil
    var totalPromptTokens: Int? = nil
    var lastPrediction: PredictionTelemetry? = nil
    var runtimeDeviceIdentifier: String? = nil
    var endpointURL: URL? = nil
    var draftModelName: String? = nil
    var gatewayRequestStage: String? = nil
    var gatewayCalls: Int? = nil      // appels reçus par l'endpoint RailRouter depuis son démarrage
    var gatewayInFlight = 0           // appels en cours (simultanés) via l'endpoint

    /// A loaded model is not evidence of an active inference or a zero token count.
    var liveTelemetryExplanation: String {
        switch engine {
        case .lmStudio:
            return L("Tokens en direct indisponibles : lms ps fournit l’état, pas les compteurs d’une requête externe.")
        case .ollama, .cloud:
            if gatewayRequestStage != nil || lastPrediction?.source == "Endpoint RailRouter" {
                return L("Suivi via l’endpoint RailRouter ; pourcentage précis du prompt non exposé par Ollama.")
            }
            return L("Activité et tokens indisponibles hors endpoint RailRouter : /api/ps ne les expose pas.")
        case .mlxDirect:
            if endpointURL == nil, gatewayCalls != nil { return L("Suivi via l’endpoint RailRouter ; progression précise non exposée.") }
            return endpointURL == nil ? L("Processus hors endpoint : activité et tokens non exposés.") : L("Progression précise non exposée ; les statistiques de la dernière requête proviennent du serveur MLX.")
        case .openRouter, .alibaba, .provider, .unknown:
            return L("Activité et tokens indisponibles : le processus ne fournit pas de télémétrie d’inférence.")
        }
    }

    /// Taille lisible : "17.38 GB" / "1.2 GB" / "650 Mo"
    var sizeLabel: String {
        let bytes = sizeBytes ?? Int64(ram_MB) * 1024 * 1024
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f Mo", ram_MB)
    }

    /// "1m" / "60s" / "2h"
    var ttlLabel: String? {
        guard let ms = ttlMs, ms > 0 else { return nil }
        let s = Int((ms / 1000).rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(Int((Double(s)/60).rounded()))m" }
        if s > 365 * 86_400 { return "∞" }   // Ollama keep_alive -1 : expires_at à des siècles
        return "\(Int((Double(s)/3600).rounded()))h"
    }

    /// Durée d'inactivité depuis la dernière utilisation.
    var idleForLabel: String? {
        guard let t = lastUsedTime else { return nil }
        let s = Int(max(0, Date().timeIntervalSince(t)))
        if s < 1 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(Int((Double(s)/60).rounded()))m" }
        return "\(Int((Double(s)/3600).rounded()))h"
    }

    enum Status: String {
        case active = "Actif"
        case idle = "Idle"
        case loading = "Chargement..."
    }
}
