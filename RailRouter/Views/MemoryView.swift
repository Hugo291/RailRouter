import SwiftUI

/// Vue « En mémoire » — reproduit la barre « Loaded Models » de LM Studio :
/// badge type, nom, capacités, statut de traitement (PROCESSING PROMPT % / Idle), taille, éjection.
struct MemoryView: View {
    @EnvironmentObject var modelManager: ModelManager

    private var instances: [ModelInstance] {
        modelManager.systemStatus?.activeInstances ?? []
    }
    /// Modèles cloud Alibaba utilisés via l'endpoint depuis moins de `GatewayFallback.ttl` : « en mémoire » simulée, avec leur
    /// chaîne de repli. Un modèle API n'a rien à décharger : il sort de la liste une minute après sa dernière requête.
    private func chains(at now: Date) -> [(asked: String, state: GatewayFallback)] {
        modelManager.cloudChains.filter { now.timeIntervalSince($0.value.lastUsed) < GatewayFallback.ttl }
            .map { ($0.key, $0.value) }.sorted { $0.1.lastUsed > $1.1.lastUsed }
    }
    private var totalRAM: Double {
        modelManager.systemStatus?.totalRAM_MB ?? 0
    }

    var body: some View {
        // Une tick par seconde : compte à rebours du TTL et disparition des modèles API expirés.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(chains: chains(at: context.date), now: context.date)
        }
    }

    private func content(chains: [(asked: String, state: GatewayFallback)], now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(count: instances.count + chains.count)

                if let status = modelManager.systemStatus, status.hasConflicts {
                    ForEach(status.conflicts) { warning in
                        ConflictBanner(warning: warning)
                    }
                }

                ForEach(chains, id: \.asked) { FallbackCard(asked: $0.asked, state: $0.state, now: now) }

                if instances.isEmpty && chains.isEmpty {
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

    private func header(count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("En mémoire"))
                    .font(.title3.bold())
                Text(L(count > 1 ? "%lld modèles · %@ utilisés" : "%lld modèle · %@ utilisé", count, humanTotal))
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

                // Statut (idle / traitement) puis TTL, toujours affichée
                statusPill
                ttlPill

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
            if let calls = instance.gatewayCalls {
                Label(L("%lld appels via RailRouter · %lld en cours", calls, instance.gatewayInFlight), systemImage: "arrow.left.arrow.right")
                    .font(.caption.monospaced())
                    .foregroundStyle(instance.gatewayInFlight > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .help(L("Compté par l’endpoint RailRouter depuis son démarrage ; les appels directs au moteur ne sont pas comptés."))
            }
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

    /// « TTL 1m » : délai avant déchargement automatique ; « — » quand le moteur ne l'expose pas.
    private var ttlPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
            Text("TTL \(instance.ttlLabel ?? "—")")
        }
        .font(.caption.monospaced()).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        .help(L("Durée avant le déchargement automatique du modèle inactif."))
    }

    // Badge « Idle · il y a 2m » / « Chargé »
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

// MARK: - Carte « modèle cloud » avec chaîne de repli

/// Modèle Alibaba servi par l'endpoint : le modèle réellement utilisé, celui demandé à l'origine s'il est épuisé,
/// puis les prochains de la chaîne (liste « quota gratuit », meilleur d'abord).
struct FallbackCard: View {
    let asked: String
    let state: GatewayFallback
    let now: Date
    private var isFallback: Bool { !state.spent.isEmpty }
    private let shown = 4
    private var remaining: Int { max(0, Int((GatewayFallback.ttl - now.timeIntervalSince(state.lastUsed)).rounded(.up))) }

    private enum Step: Hashable { case spent(String), served(String), next(String), more(Int) }
    private var steps: [Step] {
        state.spent.map(Step.spent) + [.served(state.served)] + state.next.prefix(shown).map(Step.next)
            + (state.next.count > shown ? [.more(state.next.count - shown)] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "cloud")
                    Text("API")
                }
                .font(.caption.monospaced().bold())
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 20)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                Text(state.served).font(.body.weight(.medium).monospaced()).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    Text("TTL \(remaining)s")
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                .help(L("Un modèle API quitte la mémoire une minute après sa dernière requête."))
                HStack(spacing: 5) {
                    Circle().fill(isFallback ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(isFallback ? L("Repli") : L("En service")).font(.caption.monospaced().bold())
                        .foregroundStyle(isFallback ? Color.orange : Color.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            }
            if isFallback {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    Text(asked == "auto" ? L("Alias auto : %@ ne répond plus", state.spent[0]) : L("Normalement %@ : épuisé, remplacé depuis", asked))
                    Text(state.since, style: .time)
                }
                .font(.caption.monospaced())
            } else {
                Label(asked == "auto" ? L("Alias auto : meilleur modèle gratuit restant") : (state.next.isEmpty ? L("API Alibaba Cloud") : L("Quota gratuit Alibaba")), systemImage: "cloud")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        chip(step)
                    }
                }
            }
            .help(L("Chaîne de repli : modèles épuisés, modèle en service, puis les prochains à essayer (fichier alibaba-free-quota.txt)."))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(isFallback ? AnyShapeStyle(Color.orange.opacity(0.06)) : AnyShapeStyle(.quaternary.opacity(0.25))))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isFallback ? Color.orange.opacity(0.5) : Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func chip(_ step: Step) -> some View {
        switch step {
        case .spent(let id):
            Text(id).strikethrough().foregroundStyle(.secondary).chip()
        case .served(let id):
            Text(id).bold().chip(tint: isFallback ? .orange : .green)
        case .next(let id):
            Text(id).chip()
        case .more(let count):
            Text("+\(count)").foregroundStyle(.secondary).chip()
        }
    }
}

private extension View {
    func chip(tint: Color? = nil) -> some View {
        font(.caption.monospaced()).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((tint ?? Color.secondary).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
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
