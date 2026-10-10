import Foundation

/// Ce que l'on sait de la compatibilité d'un modèle avec Codex (test `CodexProbe`, modèles Alibaba seulement).
enum CodexCompat: Equatable {
    case notTestable, untested, testing, compatible, incompatible(String?)

    var label: String {
        switch self {
        case .notTestable: return "—"
        case .untested: return L("Non testé")
        case .testing: return L("Test en cours…")
        case .compatible: return L("Compatible")
        case .incompatible: return L("Incompatible")
        }
    }
}

/// Modèles proposés dans le sélecteur de Codex. Le choix est écrit dans `~/.codex/local-models/selection.json`
/// (`hidden` : retirés ; `added` : ajoutés alors qu'ils ne le sont pas par défaut), que lit `catalog.py`
/// (commande du LaunchAgent `com.hugo.codex-catalog`) pour régénérer `catalog.json`. Codex relit la liste à son démarrage.
@MainActor
final class CodexSelection: ObservableObject {
    static let agentLabel = "com.hugo.codex-catalog"
    private let directory: URL
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var added: Set<String> = []
    @Published private(set) var catalogCount: Int?
    @Published private(set) var catalogDate: Date?
    @Published private(set) var syncing = false
    /// Verdicts du test de compatibilité, gardés d'un lancement à l'autre ; `testing` : essais en cours.
    @Published private(set) var verdicts: [String: CodexVerdict] = [:]
    @Published private(set) var testing: Set<String> = []
    private static let verdictsKey = "codexVerdicts"
    private var syncTask: Task<Void, Never>?
    private var pendingSync = false

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/local-models")) {
        self.directory = directory
        if let data = UserDefaults.standard.data(forKey: Self.verdictsKey),
           let saved = try? JSONDecoder().decode([String: CodexVerdict].self, from: data) { verdicts = saved }
        if let data = try? Data(contentsOf: selectionURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            hidden = Set(json["hidden"] ?? [])
            added = Set(json["added"] ?? [])
        }
        reloadCatalog()
    }

    private var selectionURL: URL { directory.appendingPathComponent("selection.json") }
    private var catalogURL: URL { directory.appendingPathComponent("catalog.json") }
    /// Sans `catalog.py`, pas de Codex à piloter : les contrôles sont masqués.
    var isAvailable: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog.py").path) }

    /// Alibaba (172 modèles payants) et les fournisseurs cloud branchés par clé sont à ajouter un par un ; les autres sources y sont par défaut.
    static func includedByDefault(_ model: LLMModel) -> Bool { model.source != .alibaba && model.source != .provider }

    func contains(_ model: LLMModel) -> Bool {
        Self.includedByDefault(model) ? !hidden.contains(model.id) : added.contains(model.id)
    }

    /// Alibaba n'annonce pas ce que son endpoint Responses gère : on essaie. Les autres sources sont filtrées
    /// par `catalog.py` (outils requis) et un essai chargerait le modèle en mémoire.
    static func isTestable(_ model: LLMModel) -> Bool { model.source == .alibaba }

    func compat(_ model: LLMModel) -> CodexCompat {
        guard Self.isTestable(model) else { return .notTestable }
        if testing.contains(model.id) { return .testing }
        guard let verdict = verdicts[model.id] else { return .untested }
        return verdict.compatible ? .compatible : .incompatible(verdict.reason)
    }

    /// Teste les modèles jamais testés ou dont le verdict a plus de 7 jours.
    func testPending(_ models: [LLMModel]) {
        let stale = Date.now.addingTimeInterval(-7 * 86400)
        test(models.filter { Self.isTestable($0) && (verdicts[$0.id].map { $0.date < stale } ?? true) }.map(\.id))
    }

    /// Essais en parallèle, 4 à la fois. Un essai non concluant (réseau, clé, quota) garde l'ancien verdict.
    func test(_ ids: [String]) {
        let todo = ids.filter { !testing.contains($0) }
        guard !todo.isEmpty else { return }
        testing.formUnion(todo)
        Task {
            await withTaskGroup(of: (String, CodexVerdict?).self) { group in
                var next = todo.makeIterator()
                for _ in 0..<4 { if let id = next.next() { group.addTask { (id, await CodexProbe.run(id)) } } }
                while let (id, verdict) = await group.next() {
                    testing.remove(id)
                    if let verdict { verdicts[id] = verdict; saveVerdicts() }
                    if let id = next.next() { group.addTask { (id, await CodexProbe.run(id)) } }
                }
            }
        }
    }

    private func saveVerdicts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(verdicts), forKey: Self.verdictsKey)
    }

    func set(_ model: LLMModel, included: Bool) {
        if Self.includedByDefault(model) {
            if included { hidden.remove(model.id) } else { hidden.insert(model.id) }
        } else {
            if included { added.insert(model.id) } else { added.remove(model.id) }
        }
        let json = ["hidden": hidden.sorted(), "added": added.sorted()]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: selectionURL, options: .atomic)
        }
        // Plusieurs cases cochées d'affilée → une seule régénération.
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// Lance `catalog.py` avec la commande de son LaunchAgent (pas `launchctl kickstart` : launchd espace les lancements
    /// et le laisse en « spawn scheduled »). Un clic pendant une régénération en relance une à la fin.
    func sync() {
        guard !syncing else { pendingSync = true; return }
        let agent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
        guard let command = NSDictionary(contentsOf: agent)?["ProgramArguments"] as? [String], let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncing = false
                self.reloadCatalog()
                if self.pendingSync { self.pendingSync = false; self.sync() }
            }
        }
        do { try process.run(); syncing = true } catch { syncing = false }
    }

    func reloadCatalog() {
        catalogDate = (try? FileManager.default.attributesOfItem(atPath: catalogURL.path))?[.modificationDate] as? Date
        catalogCount = (try? Data(contentsOf: catalogURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["models"] as? [Any])?.count }
    }
}
