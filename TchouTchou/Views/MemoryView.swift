import SwiftUI

/// Vue « En mémoire » — reproduit la barre « Loaded Models » de LM Studio :
/// badge type, nom, capacités, statut de traitement (PROCESSING PROMPT % / Idle), taille, éjection.
struct MemoryView: View {
    @EnvironmentObject var modelManager: ModelManager

    private var instances: [ModelInstance] {
        modelManager.systemStatus?.activeInstances ?? []
    }
    private var totalRAM: Double {
        modelManager.systemStatus?.totalRAM_MB ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let status = modelManager.systemStatus, status.hasConflicts {
                    ForEach(status.conflicts) { warning in
                        ConflictBanner(warning: warning)
                    }
                }

                if instances.isEmpty {
                    emptyState
                } else {
                    ForEach(instances) { instance in
                        LoadedModelCard(instance: instance, telemetryExplanation: modelManager.telemetryExplanation) {
                            modelManager.unload(instance)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("En mémoire"))
                    .font(.title3.bold())
                Text(L(instances.count > 1 ? "%lld modèles · %@ utilisés" : "%lld modèle · %@ utilisé", instances.count, humanTotal))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                modelManager.refreshStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L("Actualiser"))
        }
    }

    private var humanTotal: String {
        if totalRAM >= 1024 { return String(format: "%.2f GB", totalRAM / 1024) }
        return String(format: "%.0f Mo", totalRAM)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz").font(.largeTitle).foregroundStyle(.tertiary)
            Text(L("Aucun modèle en mémoire")).font(.headline)
            Text(L("Les modèles chargés dans Ollama, LM Studio ou MLX direct apparaîtront ici."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Carte « modèle chargé » (style LM Studio)

struct LoadedModelCard: View {
    let instance: ModelInstance
    var telemetryExplanation = L("Aucune statistique observée depuis le début du suivi.")
    var onEject: () -> Void

    private var name: String { instance.displayName ?? instance.modelName }
    private var busy: Bool { instance.processState.isBusy || instance.gatewayRequestStage != nil }
    private var activityLabel: String { instance.processState.isBusy ? instance.processState.label : instance.gatewayRequestStage ?? instance.processState.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Ligne principale ──
            HStack(spacing: 10) {
                // Badge type (llm / vlm / embedding)
                HStack(spacing: 4) {
                    Image(systemName: typeIcon)
                    Text(typeLabel)
                }
                .font(.caption.monospaced().bold())
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 20)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))

                Image(systemName: instance.engine.systemImage).foregroundStyle(.secondary).help(instance.engine.rawValue)
                // Nom
                Text(name)
                    .font(.body.weight(.medium).monospaced())
                    .lineLimit(1)

                // Capacités
                if instance.vision == true {
                    IconBadge("eye", tip: L("Vision"))
                }
                if instance.tools == true {
                    IconBadge("wrench.and.screwdriver", tip: L("Outils"))
                }

                Spacer(minLength: 8)

                // Statut (TTL / idle)
                statusPill

                // Taille
                HStack(spacing: 4) {
                    Text(instance.engine == .mlxDirect ? "RAM" : L("Taille")).foregroundStyle(.secondary)
                    Text(instance.sizeLabel)
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))

                // Éjecter
                Button(action: onEject) {
                    Image(systemName: "power")
                }
                .help(L("Éjecter"))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // ── Ligne statut de traitement (PROCESSING PROMPT / GENERATING / Idle) ──
            activityBar
            if let endpoint = instance.endpointURL {
                Label(endpoint.absoluteString, systemImage: "network")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            if let draft = instance.draftModelName {
                Label(L("Brouillon MTP : ") + draft, systemImage: "bolt")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            telemetryDetails
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(busy ? Color.orange.opacity(0.5) : Color.primary.opacity(0.08))
        )
    }

    // Badge « Idle · TTL 1m · il y a 2m » / « Chargé »
    @ViewBuilder
    private var statusPill: some View {
        let ps = instance.processState
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.small)
                Text(activityLabel).font(.caption.monospaced().bold()).foregroundStyle(.orange)
                if ps == .processingPrompt, let pct = instance.processingPromptPercent, pct.isFinite, (0...100).contains(pct) {
                    Text(String(format: "%.1f%%", pct)).font(.caption.monospaced().bold()).foregroundStyle(.orange)
                }
            } else if ps == .idle {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(statusTextIdle).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                Text(L("Chargé")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    private var statusTextIdle: String {
        var parts = [L("Inactif")]
        if let ttl = instance.ttlLabel { parts.append("TTL \(ttl)") }
        if let ago = instance.idleForLabel { parts.append(ago) }
        return parts.joined(separator: " · ")
    }

    // Barre d'activité animée en haut de la carte quand busy.
    @ViewBuilder
    private var activityBar: some View {
        if busy {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Text(activityLabel)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.orange)
                Spacer()
                if let ctx = instance.contextLength, ctx > 0 {
                    Text("ctx \(ctx)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var telemetryDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if instance.processState == .processingPrompt,
               let processed = instance.processedPromptTokens, let total = instance.totalPromptTokens {
                Text(L("Prompt : %lld / %lld tokens traités", processed, total))
                    .font(.caption.monospaced())
            } else if instance.processState == .processingPrompt {
                Text(L("Progression du prompt non exposée par le moteur"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let stats = instance.lastPrediction {
                let metrics = [
                    stats.promptTokens.map { L("prompt %lld tokens", $0) },
                    stats.generatedTokens.map { L("générés %lld tokens", $0) },
                    stats.tokensPerSecond.map { String(format: "%.1f tok/s", $0) }
                ].compactMap { $0 }.joined(separator: " · ")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(L("Dernière prédiction terminée"))
                        Text(stats.completedAt, style: .time)
                    }
                    Text(metrics).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption.monospaced())
                .help(L("Mesures : ") + stats.source + L(". Requête terminée, pas les compteurs de la requête en cours."))
            } else if instance.engine == .lmStudio {
                Text(telemetryExplanation).font(.caption).foregroundStyle(.secondary)
            }
            Text(instance.liveTelemetryExplanation)
                .font(.caption).foregroundStyle(.secondary)
            if !busy, let context = instance.contextLength, context > 0 {
                Text(L("Contexte configuré : %lld tokens", context))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var cardFill: AnyShapeStyle {
        busy ? AnyShapeStyle(Color.orange.opacity(0.06)) : AnyShapeStyle(.quaternary.opacity(0.25))
    }

    private var typeIcon: String {
        switch instance.typeLabel {
        case "vlm": return "eye"
        case "embedding", "embeddings": return "point.3.connected.trianglepath.dotted"
        default: return "text.bubble"
        }
    }
    private var typeLabel: String {
        instance.typeLabel ?? "llm"
    }
}

private struct IconBadge: View {
    let symbol: String
    let tip: String
    init(_ symbol: String, tip: String) { self.symbol = symbol; self.tip = tip }
    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(tip)
    }
}
