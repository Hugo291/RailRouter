import Foundation

/// Détecte les conflits de double-chargement.
/// C'est LE mécanisme critique : éviter qu'un modèle soit chargé simultanément
/// dans plusieurs moteurs (ex: LM Studio + Ollama, ou MLX direct = double RAM).
///
/// La comparaison passe par `ModelName.normalize` qui aligne les conventions
/// de nommage de chaque moteur (tags Ollama, suffixes LM Studio/MLX, préfixes
/// éditeurs) — voir Models/ModelName.swift.
actor ConflictDetector {

    /// Analyse la liste des instances actives et retourne les conflits
    /// (critiques en premier).
    func detectConflicts(instances: [ModelInstance]) -> [SystemStatus.ConflictWarning] {
        var byKey: [String: [ModelInstance]] = [:]

        for instance in instances {
            let key = ModelName.normalize(instance.modelName)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(instance)
        }

        var warnings: [SystemStatus.ConflictWarning] = []
        for (key, group) in byKey where group.count > 1 {
            let engines = Set(group.map { $0.engine }).map { $0.rawValue }.sorted()
            let severity: SystemStatus.ConflictWarning.Severity =
                Set(group.map { $0.engine }).count > 1 ? .critical : .warning

            warnings.append(SystemStatus.ConflictWarning(
                modelName: group.first?.displayName ?? group.first?.modelName ?? key,
                engines: engines,
                message: Self.message(for: group),
                severity: severity
            ))
        }

        // Les conflits critiques (2+ moteurs) d'abord.
        warnings.sort { $0.severity == .critical && $1.severity != .critical }
        return warnings
    }

    /// Message explicite : quoi, où, combien de RAM.
    private static func message(for group: [ModelInstance]) -> String {
        let totalRAM = group.reduce(0) { $0 + $1.ram_MB }
        let ramText = totalRAM >= 1024
            ? String(format: "%.1f Go", totalRAM / 1024)
            : String(format: "%.0f Mo", totalRAM)

        let engines = Set(group.map { $0.engine.rawValue })
        let whereClause = engines.count > 1
            ? L("sur %lld moteurs (%@)", engines.count, engines.sorted().joined(separator: " + "))
            : L("%lld fois dans %@", group.count, (engines.first ?? "").lowercased())

        let display = group.map { $0.displayName ?? $0.modelName }
        let name = display.first ?? "?"
        let variants = Set(display)
        let suffix = variants.count > 1 ? " (\(display.joined(separator: ", ")))" : ""

        return L("« %@%@ » est chargé %@ fois %@. RAM cumulée : %@. → Éjectez les instances en double pour libérer la mémoire.", "\(name)", "\(suffix)", "\(group.count)", "\(whereClause)", "\(ramText)")
    }
}
