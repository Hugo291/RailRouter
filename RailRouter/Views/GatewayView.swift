import SwiftUI
import AppKit

struct GatewayView: View {
    @EnvironmentObject var manager: ModelManager
    var body: some View { GatewayPanel(controller: manager.gateway, codex: manager.codex, manager: manager) }
}

private struct GatewayPanel: View {
    @ObservedObject var controller: GatewayController
    @ObservedObject var codex: CodexSelection
    @ObservedObject var manager: ModelManager

    var body: some View {
        Form {
            serviceSection
            routingSection
            ProvidersSection(manager: manager)
            if codex.isAvailable { codexSection }
            activitySection
            identifiersSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .task { await controller.refresh(); codex.reloadCatalog() }
    }

    // MARK: Service

    private var serviceSection: some View {
        Section {
            HStack(spacing: 12) {
                AppIconView(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Un endpoint pour vos modèles")).font(.headline)
                    HStack(spacing: 6) {
                        if controller.busy { ProgressView().controlSize(.mini) }
                        Circle().fill(controller.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(controller.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Action rare : rangée dans un menu plutôt qu'un gros bouton.
                Menu {
                    Button(controller.running ? L("Arrêter le service") : L("Démarrer le service")) {
                        if controller.running { controller.stop() } else { controller.start() }
                    }
                    .disabled(controller.busy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("Service"))
            }
            LabeledContent(L("Adresse")) {
                HStack(spacing: 6) {
                    Text(controller.apiURL).font(.body.monospaced()).textSelection(.enabled)
                    CopyButton(value: controller.apiURL, help: L("Copier l’adresse"))
                }
            }
            LabeledContent("APIs") {
                Text("models · chat/completions · responses · embeddings").font(.callout.monospaced()).textSelection(.enabled)
            }
        } footer: {
            Text(L("Accessible uniquement sur ce Mac · le service continue lorsque la fenêtre est fermée"))
        }
    }

    // MARK: Routage

    private var routingSection: some View {
        Section {
            routing("MLX", example: "mlx/mlx-community/Qwen3.8-27B-8bit", detail: L("Réutilise le serveur MLX déjà lancé sur 8090."), symbol: "bolt.fill", color: .orange)
            routing("Ollama", example: "qwen3.8:27b", detail: L("Modèles locaux et références cloud d’Ollama (identifiant avec « : »)."), symbol: "leaf.fill", color: .green)
            routing("LM Studio", example: L("Identifiant exact exposé par LM Studio"), detail: L("Appels directs au serveur LM Studio existant."), symbol: "cpu.fill", color: .purple)
            routing("Codex / OpenAI", example: "gpt-6.1-sol", detail: L("Compte ChatGPT de Codex : l’authentification passe telle quelle, uniquement pour ces modèles."), symbol: "sparkles", color: .teal, logo: "codex")
        } header: {
            Text(L("Routage"))
        } footer: {
            Text(L("Le champ « model » de la requête décide du moteur : celui d’un fournisseur cloud est préfixé (« deepseek/… »). Survolez une ligne pour le détail."))
        }
    }

    /// Une ligne par moteur : nom + identifiant d'exemple lisible ; le détail passe en infobulle.
    private func routing(_ name: String, example: String, detail: String, symbol: String, color: Color, logo: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let logo, ProviderLogo.image(logo) != nil {
                ProviderLogoView(id: logo, size: 22)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            Text(name).font(.body.weight(.medium)).frame(width: 120, alignment: .leading)
            Text(example).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }

    // MARK: Codex

    private var codexSection: some View {
        Section {
            LabeledContent(L("Modèles proposés")) {
                HStack(spacing: 8) {
                    if codex.syncing { ProgressView().controlSize(.small) }
                    Text(codex.catalogCount.map { "\($0)" } ?? "—").monospacedDigit()
                    if let date = codex.catalogDate {
                        Text(L("liste du %@", date.formatted(date: .abbreviated, time: .shortened))).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent(L("Liste de Codex")) {
                Button(L("Mettre à jour maintenant"), systemImage: "arrow.triangle.2.circlepath") { codex.sync() }
                    .disabled(codex.syncing)
            }
        } header: {
            Text("Codex")
        } footer: {
            Text(L("Choisissez les modèles dans Modèles, colonne « Codex » (Alibaba : à cocher un par un). La liste se régénère seule ; Codex ne la relit qu’à son démarrage."))
        }
    }

    // MARK: Activité

    private var activitySection: some View {
        Section {
            if controller.requests.isEmpty {
                Text(L("Aucune requête observée sur ce service. Les appels directs à un moteur n’apparaissent pas ici."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(controller.requests.reversed().prefix(20)), id: \.id) { request in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(request.model ?? L("Modèle non identifié")).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(request.phase)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Self.phaseColor(request.phase))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Self.phaseColor(request.phase).opacity(0.14), in: Capsule())
                        Text(request.startedAt, style: .time).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text(request.source)
                        if let tokens = request.promptTokens { Text(L("Entrée : %lld tokens", tokens)).monospacedDigit() }
                        if let tokens = request.completionTokens { Text(L("Sortie : %lld tokens", tokens)).monospacedDigit() }
                        if let status = request.status { Text("HTTP \(status)").monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(L("Activité de l’endpoint"))
        }
    }

    private static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "completed": return .green
        case "failed": return .red
        case "generating": return .orange
        default: return .secondary
        }
    }

    // MARK: Identifiants (repliés : 200+ lignes)

    private var identifiersSection: some View {
        Section {
            DisclosureGroup {
                if controller.modelIDs.isEmpty {
                    Text(L("Démarrez le service pour lister les modèles exposés.")).foregroundStyle(.secondary)
                }
                ForEach(controller.modelIDs, id: \.self) { id in
                    HStack(spacing: 6) {
                        Text(id).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        CopyButton(value: id, help: L("Copier le nom du modèle"))
                    }
                }
            } label: {
                HStack {
                    Text(L("Identifiants disponibles"))
                    Text("\(controller.modelIDs.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Actualiser"), systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                        .buttonStyle(.borderless).labelStyle(.iconOnly)
                }
            }
        }
    }
}

/// Bouton « copier » discret ; la coche confirme la copie pendant 1,2 s.
private struct CopyButton: View {
    let value: String
    let help: String
    @StateObject private var feedback = CopyFeedback()

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            feedback.flash()
        } label: {
            Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(feedback.copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

private final class CopyFeedback: ObservableObject {
    @Published var copied = false
    func flash() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copied = false }
    }
}
