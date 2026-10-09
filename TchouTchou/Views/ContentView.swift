import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        NavigationSplitView(columnVisibility: $modelManager.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            Group {
                switch modelManager.selectedSection {
                case .models: ModelsView()
                case .memory: MemoryView()
                case .discover: DiscoverView()
                case .gateway: GatewayView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(L(modelManager.selectedSection.rawValue))
        .navigationSubtitle(sectionSubtitle)
        .frame(minWidth: 1020, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if modelManager.selectedSection != .discover && modelManager.selectedSection != .gateway { refreshIndicator }
                if modelManager.selectedSection == .discover { DiscoveryToolbarControls(store: modelManager.discovery) }
                if modelManager.selectedSection == .models {
                    Menu {
                        Picker(L("Regrouper par"), selection: $modelManager.modelGrouping) {
                            ForEach(ModelGrouping.allCases) { grouping in
                                Text(grouping.title).tag(grouping)
                            }
                        }
                    } label: {
                        Label(L("Regrouper les modèles"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help(L("Regrouper les modèles"))
                }
                Button {
                    if modelManager.selectedSection == .gateway { Task { await modelManager.gateway.refresh() } }
                    else if modelManager.selectedSection == .discover { modelManager.discovery.search() }
                    else { modelManager.refreshModels() }
                } label: {
                    Label(L("Actualiser la bibliothèque"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(modelManager.isManualRefreshing)
                .help(modelManager.selectedSection == .discover ? L("Actualiser les catalogues") : L("Relire la bibliothèque et les modèles chargés (sans vérifier le registre)"))
                .keyboardShortcut("r", modifiers: .command)
                if modelManager.selectedSection == .discover {
                    DiscoveryInspectorToggle(store: modelManager.discovery)
                }
                if modelManager.selectedSection == .models {
                    Button { modelManager.selectedSection = .discover } label: {
                        Label(L("Ajouter un modèle"), systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .help(L("Ajouter un modèle"))
                    Button { modelManager.isModelDetailsVisible.toggle() } label: {
                        Label(L("Inspecteur"), systemImage: "sidebar.right")
                    }
                    .labelStyle(.iconOnly)
                    .help(modelManager.isModelDetailsVisible ? L("Masquer les détails") : L("Afficher les détails"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if modelManager.selectedSection == .models {
                if modelManager.isModelSearchActive {
                    ToolbarSearchField(text: $modelManager.modelSearch, prompt: L("Rechercher un modèle")) {
                        modelManager.isModelSearchActive = false
                    }
                } else {
                    Button { modelManager.isModelSearchActive = true } label: {
                        Label(L("Rechercher un modèle"), systemImage: "magnifyingglass")
                    }
                    .labelStyle(.iconOnly)
                    .help(L("Rechercher un modèle"))
                    .keyboardShortcut("f", modifiers: .command)
                }
                }
            }
        }
        .sheet(isPresented: errorBinding) {
            ErrorSheet(message: modelManager.errorMessage ?? "")
        }
    }

    private var sectionSubtitle: String {
        guard modelManager.selectedSection == .models else { return "" }
        return L("%lld modèles · %@", modelManager.models.count, ByteCountFormatter.string(fromByteCount: modelManager.models.reduce(0) { $0 + ($1.localSize ?? 0) }, countStyle: .file))
    }

    private var refreshIndicator: some View {
        HStack(spacing: 6) {
            if modelManager.isManualRefreshing || (modelManager.isRefreshing && modelManager.lastRefreshDate == nil) {
                ProgressView().controlSize(.small)
                Text(L("Actualisation…"))
            } else if let date = modelManager.lastRefreshDate {
                if !modelManager.refreshIssues.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(modelManager.refreshSummary)
                Text(date, style: .time).monospacedDigit()
            } else {
                Text(L("En attente d’actualisation"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help((modelManager.refreshIssues + modelManager.refreshDetails).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { modelManager.errorMessage != nil },
            set: { if !$0 { modelManager.errorMessage = nil } }
        )
    }
}

struct ErrorSheet: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(L("Erreur"))
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 400)
            Button(L("Fermer")) { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

/// Bouton pour replier / afficher le panneau de détails de Découvrir.
struct DiscoveryInspectorToggle: View {
    @ObservedObject var store: DiscoveryStore

    var body: some View {
        Button { store.isInspectorVisible.toggle() } label: {
            Label(L("Inspecteur"), systemImage: "sidebar.right")
        }
        .labelStyle(.iconOnly)
        .help(store.isInspectorVisible ? L("Masquer les détails") : L("Afficher les détails"))
    }
}

/// Filtres de Découvrir dans la barre d'outils, avec les contrôles natifs macOS (segmenté + menus).
struct DiscoveryToolbarControls: View {
    @ObservedObject var store: DiscoveryStore

    var body: some View {
        Group {
            Picker(L("Source"), selection: Binding(get: { store.source }, set: { store.source = $0 })) {
                ForEach(CatalogSource.allCases) { source in Text(source.title).tag(source) }
            }
            .pickerStyle(.segmented)
            .help(L("Catalogue à interroger"))
            Menu {
                ForEach(store.filterableCapabilities, id: \.self) { cap in
                    Toggle(CapabilityIcons.shortLabel(for: cap), isOn: Binding(
                        get: { store.capabilityFilter.contains(cap) },
                        set: { on in if on { store.capabilityFilter.insert(cap) } else { store.capabilityFilter.remove(cap) } }))
                }
                if !store.capabilityFilter.isEmpty {
                    Divider()
                    Button(L("Tout afficher")) { store.capabilityFilter = [] }
                }
            } label: {
                Label(store.capabilityFilter.isEmpty ? L("Capacités") : L("Capacités (%lld)", store.capabilityFilter.count),
                      systemImage: store.capabilityFilter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(L("Ne garder que les modèles ayant toutes les capacités cochées"))
            Menu {
                Picker(L("Trier par"), selection: Binding(get: { store.sort }, set: { store.sort = $0 })) {
                    ForEach(DiscoverySort.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(L("Trier par"), systemImage: "arrow.up.arrow.down")
            }
            .help(L("Trier les résultats"))
        }
    }
}

/// Champ de recherche natif (NSSearchField) affiché à la place de la loupe : les boutons restent collés à droite
/// tant qu'il n'est pas ouvert. Échap vide puis ferme ; il se referme aussi quand il perd le focus à vide.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.stringValue = text
        field.delegate = context.coordinator
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        init(_ parent: ToolbarSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.text.isEmpty { parent.onClose() }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if parent.text.isEmpty { parent.onClose() } else { parent.text = ""; control.stringValue = "" }
            return true
        }
    }
}
