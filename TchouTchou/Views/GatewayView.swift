import SwiftUI
import AppKit

struct GatewayView: View {
    @EnvironmentObject var manager: ModelManager
    var body: some View { GatewayPanel(controller: manager.gateway) }
}

private struct GatewayPanel: View {
    @ObservedObject var controller: GatewayController

    var body: some View {
        Form {
            header
            serviceSection
            routingSection
            clientSection
            activitySection
            modelsSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .task { await controller.refresh() }
    }

    // MARK: En-tête

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                AppIconView(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Un endpoint pour vos modèles")).font(.title2.bold())
                    Text(L("Codex, scripts et clients compatibles OpenAI partagent la même adresse. TchouTchou route chaque appel vers le bon moteur sans dupliquer les modèles en mémoire."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Service

    private var serviceSection: some View {
        Section(L("Service")) {
            LabeledContent(L("État")) {
                HStack(spacing: 8) {
                    if controller.busy { ProgressView().controlSize(.small) }
                    Circle().fill(controller.running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(controller.message)
                }
            }
            LabeledContent(L("Adresse")) {
                HStack(spacing: 6) {
                    Text(controller.apiURL).font(.body.monospaced()).textSelection(.enabled)
                    CopyButton(value: controller.apiURL, help: L("Copier l’adresse"))
                }
            }
            LabeledContent(L("Service")) {
                Button(controller.running ? L("Arrêter le service") : L("Démarrer le service")) {
                    if controller.running { controller.stop() } else { controller.start() }
                }
                .disabled(controller.busy)
            }
            Text(L("Accessible uniquement sur ce Mac · le service continue lorsque la fenêtre est fermée"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Routage

    private var routingSection: some View {
        Section {
            routing("MLX", example: "mlx/mlx-community/Qwen3.8-27B-8bit", detail: L("Réutilise le serveur MLX déjà lancé sur 8090."), symbol: "bolt.fill", color: .orange)
            routing("Ollama", example: "qwen3.8:27b", detail: L("Modèles locaux et références cloud d’Ollama (identifiant avec « : »)."), symbol: "leaf.fill", color: .green)
            routing("LM Studio", example: L("Identifiant exact exposé par LM Studio"), detail: L("Appels directs au serveur LM Studio existant."), symbol: "cpu.fill", color: .purple)
            routing("OpenRouter", example: "nvidia/nemotron-3-super-120b-a12b:free", detail: L("Modèles gratuits d’openrouter.ai, avec la clé déjà configurée pour opencode."), symbol: "cloud.fill", color: .blue)
            routing("Codex / OpenAI", example: "gpt-6.1-sol · API Responses", detail: L("Compte ChatGPT de Codex : l’authentification passe telle quelle, uniquement pour ces modèles."), symbol: "sparkles", color: .teal)
        } header: {
            Text(L("Routage"))
        } footer: {
            Text(L("Le champ « model » de la requête décide du moteur."))
        }
    }

    private func routing(_ name: String, example: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(example).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Brancher un client

    private var clientSection: some View {
        Section(L("Brancher un client")) {
            LabeledContent("Base URL") {
                HStack(spacing: 6) {
                    Text(controller.apiURL).font(.body.monospaced()).textSelection(.enabled)
                    CopyButton(value: controller.apiURL, help: L("Copier l’adresse"))
                }
            }
            LabeledContent("APIs") {
                Text("/v1/models · /v1/chat/completions · /v1/responses · /v1/embeddings")
                    .font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
            Label(L("Codex pointe déjà sur cette adresse (config.toml, wire_api = « responses »). Sa liste de modèles se met à jour automatiquement (toutes les 15 min et à chaque changement de modèles) ; relance Codex pour la voir."), systemImage: "checkmark.seal")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent(L("Catalogue MLX")) {
                Button(L("Exporter"), systemImage: "square.and.arrow.up") { controller.exportCodexCatalog() }
                    .disabled(!controller.running || !controller.modelIDs.contains(where: { $0.hasPrefix("mlx/") }))
            }
            Text(controller.catalogPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if !controller.catalogMessage.isEmpty {
                Text(controller.catalogMessage).font(.caption).foregroundStyle(.secondary)
            }
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

    // MARK: Identifiants

    private var modelsSection: some View {
        Section {
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
        } header: {
            HStack {
                Text(L("Identifiants disponibles"))
                Text("\(controller.modelIDs.count)").foregroundStyle(.secondary)
                Spacer()
                Button(L("Actualiser"), systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                    .buttonStyle(.borderless).textCase(nil)
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
