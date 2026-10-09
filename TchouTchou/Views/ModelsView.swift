import SwiftUI

// ── PIÈCES PARTAGÉES ──

struct ModelIcon: View {
    let model: LLMModel

    /// Cloud = Ollama cloud et OpenRouter : même nuage, même bleu.
    static func isCloud(_ model: LLMModel) -> Bool { model.source == .cloud || model.source == .openRouter }

    static func glyph(for model: LLMModel) -> String { isCloud(model) ? "cloud.fill" : "cube.fill" }

    var body: some View {
        Image(systemName: Self.glyph(for: model))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Self.isCloud(model) ? Color.blue : Color.teal)
            .frame(width: 18, height: 18)
            .accessibilityLabel(Self.isCloud(model) ? L("Modèle cloud") : L("Modèle local"))
    }
}

struct CapabilityIcons: View {
    let capabilities: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(capabilities, id: \.self) { cap in
                Image(systemName: Self.glyph(for: cap))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.color(for: cap))
            }
        }
    }

    static func glyph(for cap: String) -> String {
        switch cap.lowercased() {
        case "vision": return "eye.fill"
        case "tools", "tool_use": return "hammer.fill"
        case "audio": return "waveform"
        case "image", "images": return "photo.fill"
        case "embedding", "embeddings": return "point.3.connected.trianglepath.dotted"
        case "completion": return "text.bubble.fill"
        case "thinking", "reasoning": return "brain"
        case "video": return "video.fill"
        case "decision": return "arrow.triangle.branch"
        default: return "questionmark.circle"
        }
    }

    /// Libellé court pour les pastilles (« Outils » plutôt que « Outils (tool) »).
    static func shortLabel(for cap: String) -> String {
        switch cap.lowercased() {
        case "tools", "tool_use": return L("Outils")
        case "embedding", "embeddings": return L("Embeddings")
        default: return label(for: cap)
        }
    }

    static func label(for cap: String) -> String {
        switch cap.lowercased() {
        case "text": return L("Texte")
        case "vision": return L("Vision")
        case "tools", "tool_use": return L("Outils (tool)")
        case "audio": return L("Audio")
        case "image", "images": return L("Images")
        case "embedding", "embeddings": return L("Embeddings")
        case "completion": return L("Génération de texte")
        case "thinking", "reasoning": return L("Raisonnement")
        case "video": return L("Vidéo")
        case "decision": return L("Décision")
        default: return cap.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func color(for cap: String) -> Color {
        switch cap.lowercased() {
        case "text": return .blue
        case "vision": return .purple
        case "tools", "tool_use": return .orange
        case "audio": return .green
        case "image", "images": return .blue
        case "embedding", "embeddings": return .teal
        case "thinking", "reasoning": return .indigo
        case "completion": return .blue
        case "decision": return .pink
        default: return .secondary
        }
    }
}

struct StatusPill: View {
    let model: LLMModel

    var body: some View {
        let (label, color): (String, Color) = model.isActive
            ? (L("Prêt"), .green)
            : (L("Non chargé"), .secondary)
        return Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct CapabilityLabels: View {
    let capabilities: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Set(capabilities)).sorted(), id: \.self) { capability in
                Label {
                    Text(CapabilityIcons.label(for: capability))
                        .font(.callout)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: CapabilityIcons.glyph(for: capability))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CapabilityIcons.color(for: capability))
                        .frame(width: 18)
                }
            }
        }
    }
}

// ── VUE MODÈLES (table + panneau détail, façon Ollama GUI) ──

struct ModelsView: View {
    @EnvironmentObject var modelManager: ModelManager
    private var filtered: [LLMModel] {
        let query = modelManager.modelSearch
        let matches = query.isEmpty ? modelManager.models : modelManager.models.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matches
    }

    private var totalSize: Int64 {
        modelManager.models.reduce(0) { $0 + ($1.localSize ?? 0) }
    }

    private var selectedModel: LLMModel? {
        guard let id = modelManager.selectedModelID else { return nil }
        return modelManager.models.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            ModelLibraryTable(models: filtered, grouping: modelManager.modelGrouping,
                              selection: $modelManager.selectedModelID,
                              sortOrder: $modelManager.modelSortOrder,
                              collapsedGroups: $modelManager.collapsedGroups)
                .frame(minWidth: 360, maxWidth: .infinity)
            if modelManager.isModelDetailsVisible {
                resizeHandle
                detailPane.frame(width: modelManager.detailsWidth)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Séparateur glissable entre la table et le panneau de détails (largeur 220–520).
    private var resizeHandle: some View {
        Divider()
            .overlay(
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = modelManager.detailsDragStart ?? modelManager.detailsWidth
                            modelManager.detailsDragStart = start
                            modelManager.detailsWidth = min(520, max(220, start - drag.translation.width))
                        }
                        .onEnded { _ in modelManager.detailsDragStart = nil })
            )
    }

    private var detailPane: some View {
        Group {
            if let model = selectedModel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ModelIcon(model: model).scaleEffect(1.8)
                        Text(model.name)
                            .font(.headline)
                            .lineLimit(2)
                    }

                    VStack(spacing: 8) {
                        detailRow(L("Source"), model.source.rawValue)
                        detailRow(L("Paramètres"), model.parameters ?? "—")
                            .help(model.parameterDescription)
                        detailRow(L("Quantification"), model.quantization ?? "—")
                        detailRow(L("Taille"), model.source == .cloud || model.source == .openRouter ? L("Cloud") : model.localSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                        if let modified = model.modified {
                            detailRow(L("Modifié"), modified.formatted(date: .numeric, time: .shortened))
                        }
                        HStack {
                            Text(L("Statut"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            StatusPill(model: model)
                        }
                        if model.activeRAM_MB > 0 {
                            detailRow("RAM", L("%.0f Mo", model.activeRAM_MB))
                        }
                    }

                    if !model.capabilities.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Capacités"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            CapabilityLabels(capabilities: model.capabilities)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if !model.isActive {
                            Button(L("Lancer")) { modelManager.loadModel(model) }
                                .buttonStyle(.borderedProminent)
                        }
                        if model.source == .ollama || model.source == .cloud {
                            Button(L("Supprimer"), role: .destructive) { modelManager.deleteModel(model) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(L("Aucune sélection"))
                        .font(.headline)
                    Text(L("Sélectionnez un modèle pour voir ses détails."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func modifiedLabel(_ date: Date) -> String {
        if Date.now.timeIntervalSince(date) < 172800 {
            return date.formatted(date: .numeric, time: .shortened)
        }
        return date.formatted(.relative(presentation: .named))
    }

}
