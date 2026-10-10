import Foundation

/// Only exact model IDs on a verified local source are attributed to memory cards.
/// Proxy phases describe transport, not percentage-of-prompt inference progress.
enum GatewayActivity {
    static func apply(_ requests: [GatewayRequestTelemetry], calls: [String: Int] = [:], to instances: inout [ModelInstance], now: Date = .now) {
        // "clef" : modèle de décision Clef, serveur MLX direct sur 8091 (route /v1/systemone).
        let sources: [LLMModel.ModelSource: [String]] = [.mlxDirect: ["mlx", "clef"], .ollama: ["ollama"], .lmStudio: ["lmStudio"]]
        for index in instances.indices {
            let name = instances[index].modelName
            guard let source = sources[instances[index].engine],
                  instances.filter({ $0.engine == instances[index].engine && $0.modelName == name }).count == 1 else { continue }
            let total = source.compactMap { calls["\($0)|\(name)"] }.reduce(0, +)
            if total > 0 { instances[index].gatewayCalls = total }
            let records = requests.filter { source.contains($0.source) && $0.upstreamModel == name && $0.startedAt <= now }
            let running = records.filter { $0.finishedAt == nil && now.timeIntervalSince($0.startedAt) <= 3600 }
            instances[index].gatewayInFlight = running.count
            if let current = running.max(by: { $0.startedAt < $1.startedAt }) {
                instances[index].gatewayRequestStage = current.phase == "generating" ? L("RÉPONSE EN COURS") : L("REQUÊTE TRANSMISE")
            }
            if let finished = records.filter({ $0.phase == "completed" && $0.finishedAt != nil && ($0.promptTokens != nil || $0.completionTokens != nil) })
                .max(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }),
               let date = finished.finishedAt, date <= now, now.timeIntervalSince(date) <= 300,
               instances[index].lastPrediction.map({ $0.completedAt < date }) ?? true {
                instances[index].lastPrediction = PredictionTelemetry(completedAt: date,
                    promptTokens: finished.promptTokens.flatMap { $0 >= 0 ? $0 : nil },
                    generatedTokens: finished.completionTokens.flatMap { $0 >= 0 ? $0 : nil },
                    tokensPerSecond: nil, source: "Endpoint RailRouter")
            }
        }
    }
}
