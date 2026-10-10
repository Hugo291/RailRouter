import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var manager: ModelManager
    var body: some View { DiscoveryBrowser(store: manager.discovery, models: manager.models) }
}

private var frenchLocale: Locale { Locale(identifier: Localization.current.resolved == .french ? "fr_FR" : "en_US") }

private extension Date {
    var monthYearFR: String { formatted(Date.FormatStyle().month(.abbreviated).year().locale(frenchLocale)) }
    var longFR: String { formatted(Date.FormatStyle(date: .long, time: .omitted).locale(frenchLocale)) }
    var longTimeFR: String { formatted(Date.FormatStyle(date: .long, time: .shortened).locale(frenchLocale)) }
    var relativeFR: String { formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated).locale(frenchLocale)) }
    var relativeNamedFR: String { formatted(.relative(presentation: .named).locale(frenchLocale)) }
}

private struct DiscoveryBrowser: View {
    @ObservedObject var store: DiscoveryStore
    let models: [LLMModel]

    private static let families = ["Qwen", "Gemma", "Llama", "Mistral", "DeepSeek"]

    var body: some View {
        VStack(spacing: 0) {
            if store.downloadEntry != nil { downloadBanner; Divider() }
            HStack(spacing: 0) {
                results.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                if store.isInspectorVisible {
                    resizeHandle
                    inspector.frame(width: store.inspectorWidth).frame(maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $store.query, placement: .toolbar, prompt: L("Rechercher une famille, un modèle ou un éditeur"))
        .searchSuggestions {
            if store.query.isEmpty {
                ForEach(Self.families, id: \.self) { name in Text(name).searchCompletion(name) }
            }
        }
        .onSubmit(of: .search) { store.search() }
        .onAppear { if !store.hasSearched { store.search() } }
        .onChange(of: store.query) { _, _ in store.search(debounce: true) }
    }

    /// Séparateur glissable entre résultats et panneau de droite (largeur 280–560).
    private var resizeHandle: some View {
        Divider()
            .overlay(
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = store.inspectorDragStart ?? store.inspectorWidth
                            store.inspectorDragStart = start
                            store.inspectorWidth = min(560, max(280, start - drag.translation.width))
                        }
                        .onEnded { _ in store.inspectorDragStart = nil })
            )
    }

    private var selection: Binding<String?> {
        Binding(
            get: { store.selected?.id },
            set: { id in
                guard let id, let entry = store.visibleEntries.first(where: { $0.id == id }) else { return }
                store.select(entry)
            }
        )
    }

    private var results: some View {
        VStack(spacing: 0) {
            if !store.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Button(L("Réessayer")) { store.search() }.controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            if store.visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    if store.searching { ProgressView().controlSize(.large) }
                    else { Image(systemName: "magnifyingglass").font(.system(size: 32)).foregroundStyle(.secondary) }
                    Text(store.searching ? L("Interrogation des catalogues…") : L("Aucun modèle trouvé")).font(.headline)
                    Text(L("Essayez un nom de famille, par exemple Qwen ou Gemma.")).font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    Section {
                        ForEach(store.visibleEntries) { entry in row(entry).tag(entry.id) }
                    } header: {
                        HStack {
                            Text(store.query.isEmpty ? L("Modèles populaires") : L("Résultats"))
                            Text("\(store.visibleEntries.count)").foregroundStyle(.secondary)
                            if store.searching { ProgressView().controlSize(.mini) }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private func sizeTips(_ sizes: [String]) -> some View {
        let maxShown = 8
        return HStack(spacing: 4) {
            ForEach(sizes.prefix(maxShown), id: \.self) { size in
                Text(size)
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if sizes.count > maxShown {
                Text("+\(sizes.count - maxShown)").font(.caption2).foregroundStyle(.secondary)
                    .help(sizes.dropFirst(maxShown).joined(separator: ", "))
            }
        }
        .help(L("Tailles disponibles : ") + sizes.joined(separator: ", "))
    }

    private func row(_ entry: CatalogEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle).help(entry.name)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail).help(entry.summary)
                }
                HStack(spacing: 6) {
                    if !entry.sizes.isEmpty { sizeTips(entry.sizes) }
                    HStack(spacing: 4) {
                        ForEach(entry.displayCapabilities, id: \.self) { cap in
                            Text(CapabilityIcons.shortLabel(for: cap))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(CapabilityIcons.color(for: cap))
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(CapabilityIcons.color(for: cap).opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            if isInstalled(entry) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L("Dans la bibliothèque"))
            }
            VStack(alignment: .trailing, spacing: 2) {
                if entry.downloads > 0 {
                    Label(entry.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .help(L("%@ téléchargements", entry.downloads.formatted()))
                }
                if let released = entry.released {
                    Text(L("Sorti ") + released.monthYearFR)
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(L("Date de sortie : ") + released.longFR)
                }
                if let updated = entry.updated {
                    Text(L("Màj ") + updated.relativeFR)
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(L("Dernière modification : ") + updated.longTimeFR)
                }
            }
            Text(entry.format.isEmpty ? entry.source.title : entry.format)
                .font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name + ", " + entry.source.title + ", " + L("%@ téléchargements", entry.downloads.formatted()) + (entry.released.map { ", " + L("sorti %@", $0.longFR) } ?? "") + (entry.updated.map { ", " + L("modifié %@", $0.relativeNamedFR) } ?? "") + (isInstalled(entry) ? ", " + L("dans la bibliothèque") : ""))
        .accessibilityHint(([entry.sizes.isEmpty ? "" : L("Tailles : %@", entry.sizes.joined(separator: ", ")),
                             L("Capacités : %@", entry.displayCapabilities.map { CapabilityIcons.shortLabel(for: $0) }.joined(separator: ", "))] + [entry.summary]).filter { !$0.isEmpty }.joined(separator: ". "))
    }

    private enum MemoryFit { case fits, tight, tooBig }

    /// macOS réserve environ 75 % de la mémoire unifiée au GPU : au-delà, le modèle ne tourne pas.
    private func memoryFit(_ option: CatalogDownloadOption) -> MemoryFit {
        guard let size = option.sizeBytes else { return .fits }
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return Double(size) > ram * 0.75 ? .tooBig : Double(size) > ram * 0.6 ? .tight : .fits
    }

    private var ramText: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }

    private func variantDetail(_ option: CatalogDownloadOption) -> String {
        var parts: [String] = []
        if let size = option.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if option.id == store.rankedOptions.first?.id { parts.append(L("recommandée")) }
        switch memoryFit(option) {
        case .tooBig: parts.append(L("impossible sur ce Mac (%@ de mémoire)", ramText))
        case .tight: parts.append(L("très juste pour %@ de mémoire", ramText))
        case .fits: break
        }
        return parts.joined(separator: " · ")
    }

    /// Ligne de variante : libellé complet, sélection au clic, téléchargement direct par l'icône.
    private func variantRow(_ option: CatalogDownloadOption, entry: CatalogEntry) -> some View {
        let fit = memoryFit(option)
        let detail = variantDetail(option)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .foregroundStyle(fit == .tooBig ? Color.red : Color.primary)
                if !detail.isEmpty {
                    Text(detail).font(.caption)
                        .fontWeight(fit == .tooBig ? .semibold : .regular)
                        .foregroundStyle(fit == .tooBig ? Color.red : fit == .tight ? Color.orange : Color.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button {
                store.optionID = option.id
                store.download()
            } label: {
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .disabled(store.downloading)
            .help(L("Télécharger %@ dans %@", option.label, entry.source.title))
            .accessibilityLabel(L("Télécharger %@ dans %@", option.label, entry.source.title))
        }
    }

    private func engineSection(_ entry: CatalogEntry) -> some View {
        Section {
            ForEach(store.engineChoices) { choice in
                Button { store.select(choice.entry) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: choice.entry.id == entry.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(choice.entry.id == entry.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(choice.entry.source.title).fontWeight(.medium)
                                if choice.recommended { Text(L("Recommandé")).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
                                if isInstalled(choice.entry) { Text(L("Déjà installé")).font(.caption).foregroundStyle(.green) }
                            }
                            Text(choice.entry.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if choice.recommended { Text(choice.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(choice.entry.id == entry.id ? [.isButton, .isSelected] : .isButton)
            }
        } header: {
            Text(L("Disponible dans deux moteurs"))
        } footer: {
            Text(L("Un seul suffit : évitez de télécharger le même modèle dans les deux."))
        }
    }

    private var inspector: some View {
        Group {
            if let entry = store.selected {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name).font(.title3.bold()).textSelection(.enabled)
                            Text(entry.source.title).font(.caption).foregroundStyle(.secondary)
                        }
                        if !entry.summary.isEmpty {
                            Text(entry.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if entry.downloads > 0 {
                            LabeledContent(L("Téléchargements"), value: entry.downloads.formatted())
                        }
                        LabeledContent(L("Capacités"), value: entry.displayCapabilities.map { CapabilityIcons.shortLabel(for: $0) }.joined(separator: ", "))
                        if let released = entry.released {
                            LabeledContent(L("Date de sortie"), value: released.longFR)
                        }
                        if let updated = entry.updated {
                            LabeledContent(L("Dernière modification"), value: updated.longTimeFR)
                        }
                        if !entry.sizes.isEmpty {
                            LabeledContent(L("Tailles"), value: entry.sizes.joined(separator: " · "))
                        }
                        Link(L("Voir la fiche du modèle"), destination: entry.pageURL)
                    }
                    if !store.engineChoices.isEmpty { engineSection(entry) }
                    Section {
                        if store.loadingOptions {
                            HStack { ProgressView().controlSize(.small); Text(L("Lecture des variantes…")) }
                        } else if let error = store.optionError {
                            Text(error).font(.callout).foregroundStyle(.orange)
                            Button(L("Réessayer")) { store.select(entry) }
                        } else {
                            if store.options.count > DiscoveryStore.variantPageSize {
                                TextField(L("Filtrer les variantes"), text: $store.variantFilter, prompt: Text(L("Filtrer (ex. q4, 8b)")))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(L("Filtrer les variantes"))
                            }
                            if store.shownOptions.isEmpty {
                                Text(L("Aucune variante ne correspond.")).foregroundStyle(.secondary)
                            } else {
                                ForEach(store.shownOptions) { option in variantRow(option, entry: entry) }
                            }
                            if store.filteredOptions.count > store.variantLimit {
                                Button(L("Afficher plus (%lld)", store.filteredOptions.count - store.variantLimit)) {
                                    store.variantLimit += DiscoveryStore.variantPageSize
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(L("Variante"))
                            Spacer()
                            if store.options.count > 1 {
                                Picker(L("Trier par"), selection: $store.variantSort) {
                                    ForEach(VariantSort.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.menu).fixedSize().labelsHidden()
                                .help(L("Trier les variantes (poids, nom…)"))
                                .accessibilityLabel(L("Trier les variantes"))
                            }
                        }
                    } footer: {
                        if !store.options.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Classées par usage courant (les catalogues ne donnent pas de téléchargements par variante). %lld au total.", store.options.count))
                                Text(L("Téléchargement sur disque uniquement. Aucun chargement en mémoire."))
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(L("Aucune sélection")).font(.headline)
                    Text(L("Sélectionnez un résultat pour choisir sa variante."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text(L("MLX et GGUF pour LM Studio · catalogue officiel pour Ollama"))
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var downloadBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if store.downloading { ProgressView().controlSize(.small) }
                else { Image(systemName: store.downloadSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle").foregroundStyle(store.downloadSucceeded ? .green : .orange) }
                Text(store.downloadEntry?.name ?? "").font(.caption.bold())
                Text(store.downloadMessage).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
            }
            if let fraction = store.downloadFraction, store.downloading {
                ProgressView(value: fraction)
            }
        }.padding(12).background(Color.accentColor.opacity(0.05))
    }

    private func isInstalled(_ entry: CatalogEntry) -> Bool {
        models.contains {
            if entry.source == .ollama {
                return ($0.source == .ollama || $0.source == .cloud) && $0.id.components(separatedBy: ":").first == entry.downloadID
            }
            return $0.source == .lmStudio && $0.id == entry.downloadID
        }
    }
}
