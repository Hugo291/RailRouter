import Foundation
import Combine

/// Tri des résultats de Découvrir.
enum DiscoverySort: String, CaseIterable, Identifiable {
    case popularity, newest, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .popularity: return L("Popularité")
        case .newest: return L("Nouveauté")
        case .name: return L("Nom")
        }
    }
}

enum VariantSort: String, CaseIterable, Identifiable {
    case recommended, sizeAscending, sizeDescending, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recommended: return L("Recommandées")
        case .sizeAscending: return L("Poids croissant")
        case .sizeDescending: return L("Poids décroissant")
        case .name: return L("Nom")
        }
    }
}

struct EngineChoice: Identifiable, Hashable, Sendable {
    let entry: CatalogEntry
    var recommended = false
    var reason = ""
    var id: String { entry.id }
}

@MainActor
final class DiscoveryStore: ObservableObject {
    @Published var inspectorWidth: CGFloat = 340
    @Published var isInspectorVisible = UserDefaults.standard.object(forKey: "discoveryDetailsVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isInspectorVisible, forKey: "discoveryDetailsVisible") }
    }
    var inspectorDragStart: CGFloat?

    @Published var query = ""
    @Published var source: CatalogSource = .all
    @Published var sort: DiscoverySort = .popularity
    /// Capacités exigées (toutes). Vide = pas de filtre.
    @Published var capabilityFilter: Set<String> = []
    @Published private(set) var entries: [CatalogEntry] = []
    @Published private(set) var issues: [String] = []
    @Published private(set) var searching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var selected: CatalogEntry?
    @Published private(set) var options: [CatalogDownloadOption] = []
    @Published var optionID = ""
    @Published var variantFilter = ""
    @Published var variantSort: VariantSort = .recommended
    @Published var variantLimit = DiscoveryStore.variantPageSize
    @Published private(set) var loadingOptions = false
    @Published private(set) var optionError: String?
    @Published private(set) var downloadEntry: CatalogEntry?
    @Published private(set) var downloadMessage = ""
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloading = false
    @Published private(set) var downloadSucceeded = false
    private let catalog = ModelCatalog()
    private var ollamaDates: [String: Date] = [:]
    private var dateTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var optionTask: Task<Void, Never>?
    var onDownloadFinished: (() -> Void)?

    var visibleEntries: [CatalogEntry] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = entries.filter { entry in
            guard source == .all || entry.source == source else { return false }
            guard capabilityFilter.isSubset(of: Set(entry.displayCapabilities)) else { return false }
            // Les catalogues renvoient aussi des résultats approximatifs : on ne garde que ceux qui contiennent la saisie.
            let haystack = (entry.name + " " + entry.summary).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
        return filtered.sorted {
            switch sort {
            case .popularity:
                if $0.downloads != $1.downloads { return $0.downloads > $1.downloads }
            case .newest:
                // Date de sortie, sinon dernière modification (Ollama n'annonce que celle-ci) ; sans date en dernier.
                let a = $0.released ?? $0.updated, b = $1.released ?? $1.updated
                if a != b { return a.map { date in b.map { date > $0 } ?? true } ?? false }
            case .name: break
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    static let variantPageSize = 10

    var rankedOptions: [CatalogDownloadOption] { CatalogDownloadOption.ranked(options) }
    var sortedOptions: [CatalogDownloadOption] {
        switch variantSort {
        case .recommended: return rankedOptions
        case .sizeAscending, .sizeDescending:
            let ascending = variantSort == .sizeAscending
            // Les variantes sans taille connue restent en fin de liste.
            return options.sorted {
                switch ($0.sizeBytes, $1.sizeBytes) {
                case let (a?, b?) where a != b: return ascending ? a < b : a > b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return $0.label.localizedStandardCompare($1.label) == .orderedAscending
                }
            }
        case .name: return options.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }
    var filteredOptions: [CatalogDownloadOption] {
        let term = variantFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? sortedOptions : sortedOptions.filter { $0.label.localizedCaseInsensitiveContains(term) }
    }
    /// Les `variantLimit` premières variantes ; la variante choisie reste toujours visible.
    var shownOptions: [CatalogDownloadOption] {
        var shown = Array(filteredOptions.prefix(variantLimit))
        if let chosen = selectedOption, !shown.contains(chosen) { shown.append(chosen) }
        return shown
    }
    var engineChoices: [EngineChoice] { Self.engineChoices(selected: selected, related: relatedEntries) }

    /// Un choix par moteur (le meilleur résultat de chaque) et une recommandation expliquée.
    /// Règle de RailRouter, pas un benchmark : MLX est le format natif d'Apple Silicon.
    nonisolated static func engineChoices(selected: CatalogEntry?, related: [CatalogEntry]) -> [EngineChoice] {
        guard let selected, !related.isEmpty else { return [] }
        func best(_ source: CatalogSource) -> CatalogEntry? {
            let pool = ([selected] + related).filter { $0.source == source }
            if source == selected.source { return selected }
            return pool.max { a, b in
                let am = a.format.uppercased() == "MLX", bm = b.format.uppercased() == "MLX"
                return am != bm ? bm : a.downloads < b.downloads
            }
        }
        var choices = [CatalogSource.ollama, .lmStudio].compactMap { best($0) }.map { EngineChoice(entry: $0) }
        guard choices.count > 1 else { return [] }
        if let mlx = choices.firstIndex(where: { $0.entry.source == .lmStudio && $0.entry.format.uppercased() == "MLX" }) {
            choices[mlx].recommended = true
            choices[mlx].reason = L("Format MLX, natif Apple Silicon : en général le plus rapide sur Mac.")
        } else if let ollama = choices.firstIndex(where: { $0.entry.source == .ollama }) {
            choices[ollama].recommended = true
            choices[ollama].reason = L("Catalogue officiel, variantes clairement nommées, installation en une commande.")
        }
        return choices
    }

    /// Capacités proposables au filtre, dans un ordre stable.
    var filterableCapabilities: [String] {
        let present = Set(entries.flatMap(\.displayCapabilities))
        return ["text", "vision", "tools", "thinking", "audio", "video", "embedding"].filter { present.contains($0) }
    }

    var selectedOption: CatalogDownloadOption? { options.first { $0.id == optionID } }
    var relatedEntries: [CatalogEntry] {
        guard let selected, !selected.familyKey.isEmpty else { return [] }
        return entries.filter { $0.source != selected.source && $0.familyKey == selected.familyKey }
    }

    func search(debounce: Bool = false) {
        searchTask?.cancel()
        searching = true
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            if debounce {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
            let result = await catalog.search(query: term)
            guard !Task.isCancelled else { return }
            entries = result.entries.map { withKnownDate($0) }
            loadOllamaDates()
            issues = result.issues
            searching = false
            hasSearched = true
            // Discard a stale selection after a different search, not while changing filters.
            if let selected, !entries.contains(where: { $0.id == selected.id }) { select(nil) }
        }
    }

    private func withKnownDate(_ entry: CatalogEntry) -> CatalogEntry {
        guard entry.source == .ollama, entry.updated == nil, let date = ollamaDates[entry.id] else { return entry }
        var entry = entry
        entry.updated = date
        return entry
    }

    /// Ollama n'annonce la date que sur la fiche du modèle : lecture en arrière-plan, mise en cache.
    private func loadOllamaDates() {
        dateTask?.cancel()
        let missing = entries.filter { $0.source == .ollama && $0.updated == nil }
        guard !missing.isEmpty else { return }
        dateTask = Task {
            await withTaskGroup(of: (String, Date?).self) { group in
                for entry in missing { group.addTask { (entry.id, await self.catalog.ollamaUpdated(for: entry)) } }
                for await (id, date) in group {
                    guard !Task.isCancelled, let date else { continue }
                    ollamaDates[id] = date
                    entries = entries.map { $0.id == id ? withKnownDate($0) : $0 }
                }
            }
        }
    }

    func select(_ entry: CatalogEntry?) {
        optionTask?.cancel()
        selected = entry
        options = []
        optionID = ""
        variantFilter = ""
        variantLimit = Self.variantPageSize
        optionError = nil
        loadingOptions = entry != nil
        guard let entry else { return }
        optionTask = Task {
            do {
                let fetched = try await catalog.downloadOptions(for: entry)
                guard !Task.isCancelled else { return }
                options = fetched
                // No implicit latest/huge variant: user chooses deliberately.
                if fetched.count == 1 { optionID = fetched[0].id }
                if fetched.isEmpty { optionError = L("Aucune variante téléchargeable trouvée.") }
            } catch {
                guard !Task.isCancelled else { return }
                optionError = error.localizedDescription
            }
            loadingOptions = false
        }
    }

    func download() {
        guard !downloading, let entry = selected, let option = selectedOption else { return }
        downloading = true
        downloadSucceeded = false
        downloadEntry = entry
        downloadMessage = L("Connexion à %@…", "\(entry.source.title)")
        downloadFraction = nil
        Task { [self] in
            do {
                try await CatalogDownload.run(entry: entry, option: option) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.downloading == true else { return }
                        self?.downloadMessage = progress.message
                        self?.downloadFraction = progress.fraction
                    }
                }
                downloadSucceeded = true
                downloadMessage = L("Téléchargé dans %@ · modèle non chargé", "\(entry.source.title)")
                downloadFraction = 1
                onDownloadFinished?()
            } catch {
                downloadMessage = error.localizedDescription
                downloadFraction = nil
            }
            downloading = false
        }
    }
}
