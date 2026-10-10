import Foundation

/// Représente un modèle LLM dans la bibliothèque
struct LLMModel: Identifiable, Hashable {
    let id: String              // "qwen3.5:0.8b-mlx"
    let name: String            // Affichage
    var parameters: String?     // "4.2B"
    var quantization: String?   // "Q8_0", "mxfp8", "FP8"
    let sizeBytes: Int64        // Taille sur disque
    var capabilities: [String]  // ["Vision", "Outils", "Réflexion"]
    let modified: Date?
    let source: ModelSource     // D'où il vient
    
    /// Exact count when provided by model metadata; display may be rounded.
    var reportedParameterCount: Double? = nil
    /// Tarif à la demande (Alibaba) ; nil pour les modèles locaux, gratuits ou sans tarif publié.
    var price: TokenPrice? = nil

    // Runtime state
    var isActive: Bool = false
    var activeEngine: ModelSource? = nil
    var activeRAM_MB: Double = 0

    var sourceSortKey: String { source.rawValue }
    var capabilitiesSortKey: String { capabilities.sorted().joined(separator: ", ") }
    var parametersSortKey: Double { parameterCount ?? -1 }
    var quantizationSortKey: Double { quantizationBits ?? -1 }
    var modifiedSortKey: Date { modified ?? .distantPast }
    /// Gratuit : modèle local, ou modèle « :free » d'OpenRouter (seuls ceux-là sont listés).
    var isFree: Bool { source == .openRouter || !isCloudHosted }
    var priceSortKey: Double { price?.blended ?? (isFree ? 0 : -1) }
    
    /// Counts reported by providers, never guessed from a filename.
    var parameterCount: Double? { reportedParameterCount ?? Self.parameterValue(parameters) }
    var parameterDescription: String {
        if let count = reportedParameterCount {
            return L("%@ paramètres", "\(count.formatted(.number.precision(.fractionLength(0))))")
        }
        guard let parameters, Self.parameterValue(parameters) != nil else { return L("Nombre de paramètres non fourni") }
        if source == .alibaba { return L("%@ paramètres (d’après le nom du modèle ; Alibaba ne publie pas ce chiffre)", "\(parameters)") }
        if source == .openRouter { return L("%@ paramètres (d’après le nom ou la description annoncés par OpenRouter)", "\(parameters)") }
        if source == .provider { return L("%@ paramètres (d’après le nom du modèle ; le fournisseur ne publie pas ce chiffre)", "\(parameters)") }
        return L("%@ paramètres (valeur fournie par le moteur)", "\(parameters)")
    }
    var quantizationBits: Double? { Self.bitValue(quantization) }
    var librarySource: String {
        if source == .provider { return CloudProviders.route(model: id)?.provider.name ?? source.rawValue }
        return source == .cloud ? "Ollama" : source.rawValue
    }
    var sizeSortKey: Int64 { localSize ?? -1 }
    var isCloudHosted: Bool { source == .cloud || source == .openRouter || source == .alibaba || source == .provider }
    var localSize: Int64? { isCloudHosted || sizeBytes <= 0 ? nil : sizeBytes }

    /// Runtime identity is source-specific; family normalization only detects conflicts.
    static func libraryModel(for instance: ModelInstance, in models: [LLMModel]) -> LLMModel? {
        let candidates = models.filter { $0.source == instance.engine || ($0.source == .cloud && instance.engine == .ollama) }
        let identifiers = [instance.modelName, instance.displayName].compactMap { $0?.lowercased() }
        if let exact = candidates.first(where: { identifiers.contains($0.id.lowercased()) || identifiers.contains($0.name.lowercased()) }) { return exact }
        let similar = candidates.filter { ModelName.sameModel($0.id, instance.modelName) || ModelName.sameModel($0.name, instance.modelName) }
        return similar.count == 1 ? similar.first : nil
    }

    static func parameterValue(_ text: String?) -> Double? {
        guard let text else { return nil }
        let value = text.uppercased().replacingOccurrences(of: ",", with: ".")
        guard let range = value.range(of: #"[0-9]+(?:\.[0-9]+)?\s*[KMBT]"#, options: .regularExpression) else { return nil }
        let token = String(value[range]).replacingOccurrences(of: " ", with: "")
        guard let unit = token.last, let number = Double(token.dropLast()) else { return nil }
        let factors: [Character: Double] = ["K": 1e3, "M": 1e6, "B": 1e9, "T": 1e12]
        return number * (factors[unit] ?? 1)
    }

    static func bitValue(_ text: String?) -> Double? {
        guard let text else { return nil }
        let value = text.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard let range = value.range(of: #"^(?:(?:IQ|Q|NVFP|MXFP|BF|FP|F)[0-9]+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?BITS?)"#, options: .regularExpression),
              let digits = value[range].range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        return Double(value[digits])
    }

    enum ModelSource: String, CaseIterable {
        case ollama = "Ollama"
        case lmStudio = "LM Studio"
        case mlxDirect = "MLX"
        case cloud = "Cloud"
        case openRouter = "OpenRouter"
        case alibaba = "Alibaba"
        /// Fournisseur cloud branché par clé (DeepSeek, Groq, Mistral…) : voir `CloudProviders`.
        case provider = "API"
        case unknown = "—"
    }
}
