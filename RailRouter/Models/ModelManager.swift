import Foundation
import SwiftUI
import Combine
import AppKit

// MARK: - Navigation

enum AppSection: String, CaseIterable, Identifiable {
    case models = "Modèles"
    case memory = "En mémoire"
    case discover = "Découvrir"
    case gateway = "Endpoint"
    var id: String { rawValue }
}

enum ModelGrouping: String, CaseIterable, Identifiable {
    case none, source, parameters, quantization, size, capabilities, modified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return L("Aucun")
        case .source: return "Source"
        case .parameters: return L("Paramètres")
        case .quantization: return L("Quantification")
        case .size: return L("Taille")
        case .capabilities: return L("Capacités")
        case .modified: return L("Modifié")
        }
    }
    func key(_ model: LLMModel) -> String {
        switch self {
        case .none: return ""
        case .source: return model.librarySource
        case .parameters: return model.parameterCount.map { String(format: "%024.0f", $0) } ?? "~"
        case .quantization: return model.quantizationBits.map { String(format: "%06.2f", $0) } ?? "~"
        case .size:
            guard let size = model.localSize else { return model.isCloudHosted ? "6" : "7" }
            switch size { case ..<1_000_000_000: return "1"; case ..<5_000_000_000: return "2"; case ..<20_000_000_000: return "3"; case ..<50_000_000_000: return "4"; default: return "5" }
        case .capabilities: return model.capabilitiesSortKey.isEmpty ? "~" : model.capabilitiesSortKey
        case .modified:
            guard let date = model.modified else { return "7" }
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: .now)).day ?? 0
            switch days { case ...0: return "1"; case 1: return "2"; case 2...6: return "3"; case 7...29: return "4"; case 30...364: return "5"; default: return "6" }
        }
    }

    func label(_ model: LLMModel) -> String {
        switch self {
        case .none: return ""
        case .source: return model.librarySource
        case .parameters:
            guard let count = model.parameterCount else { return L("Paramètres inconnus") }
            return count >= 1e12 ? "\(count / 1e12) T" : count >= 1e9 ? "\(count / 1e9) B" : "\(count / 1e6) M"
        case .quantization: return model.quantizationBits.map { "\($0.formatted()) bits" } ?? "Quantification inconnue"
        case .size: return ["1": L("Moins de 1 Go"), "2": L("1 à 5 Go"), "3": L("5 à 20 Go"), "4": L("20 à 50 Go"), "5": L("50 Go et plus"), "6": L("Cloud"), "7": L("Taille inconnue")][key(model)] ?? ""
        case .capabilities: return model.capabilities.isEmpty ? L("Capacités inconnues") : model.capabilities.sorted().map { CapabilityIcons.label(for: $0) }.joined(separator: " · ")
        case .modified: return ["1": L("Aujourd’hui"), "2": L("Hier"), "3": L("Cette semaine"), "4": L("Ce mois-ci"), "5": L("Cette année"), "6": L("Plus ancien"), "7": L("Date inconnue")][key(model)] ?? ""
        }
    }
}

extension LLMModel.ModelSource {
    var systemImage: String {
        switch self {
        case .ollama: return "leaf.circle.fill"
        case .lmStudio: return "cpu"
        case .mlxDirect: return "bolt.fill"
        case .cloud, .openRouter, .alibaba, .provider: return "cloud.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Orchestrateur

@MainActor
final class ModelManager: ObservableObject {

    // ── Bibliothèque ──
    @Published var models: [LLMModel] = []
    @Published var modelSearch: String = ""
    @Published var isModelSearchActive = false
    @Published var selectedModelID: String? = nil

    // ── Chat ──
    @Published var chatSessions: [ChatSession] = []
    @Published var currentSessionID: UUID? = nil
    @Published var selectedModelForChat: String? = nil
    @Published var selectedEngine: LLMModel.ModelSource = .ollama
    @Published var isBusy: Bool = false
    @Published var chatDraft: String = ""

    // ── Système / mémoire ──
    @Published var systemStatus: SystemStatus? = nil
    @Published var systemMemoryInfo: String = ""
    @Published private(set) var telemetryExplanation = L("Aucune statistique observée depuis le lancement.")
    @Published var selectedSection: AppSection = .models
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// Panneau de détails à droite ; le choix survit au redémarrage.
    @Published var isModelDetailsVisible = UserDefaults.standard.object(forKey: "modelDetailsVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isModelDetailsVisible, forKey: "modelDetailsVisible") }
    }
    /// Affiche la colonne de cases « Codex » (choix des modèles proposés à Codex).
    @Published var isCodexEditing = false
    /// Catégories repliées dans la table des modèles (clé « regroupement|groupe »).
    @Published var collapsedGroups: Set<String> = []
    @Published var detailsWidth: CGFloat = 260
    var detailsDragStart: CGFloat?
    @Published var modelGrouping: ModelGrouping = .source
    /// Langue de l'interface (Réglages, en bas de la barre latérale) ; les textes calculés sont régénérés au changement.
    @Published var language: AppLanguage = Localization.current {
        didSet {
            guard language != oldValue else { return }
            Localization.current = language
            UserDefaults.standard.set(language.rawValue, forKey: Localization.defaultsKey)
            refreshModels()
        }
    }
    @Published var modelSortOrder: [KeyPathComparator<LLMModel>] = [KeyPathComparator(\.name)]
    let discovery = DiscoveryStore()
    let gateway = GatewayController()
    let codex = CodexSelection()
    private var codexObserver: AnyCancellable?
    @Published var errorMessage: String? = nil
    @Published private(set) var isRefreshing = false
    @Published private(set) var isManualRefreshing = false
    private var hasManualRefreshResult = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var refreshSummary = ""
    @Published private(set) var refreshIssues: [String] = []
    @Published private(set) var refreshDetails: [String] = []

    var currentSession: ChatSession? {
        chatSessions.first { $0.id == currentSessionID }
    }

    // ── Services ──
    private let ollama = OllamaService()
    private let lmStudio = LMStudioService()
    private let openRouter = OpenRouterService()
    private let alibaba = AlibabaService()
    private let mlxMonitor = MLXProcessMonitor()
    private let lmTelemetry = LMStudioTelemetry()
    private let conflictDetector = ConflictDetector()
    private var refreshTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {
        // La colonne Codex du tableau dépend de ce choix : republier ses changements.
        codexObserver = codex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        let s = ChatSession()
        chatSessions = [s]
        currentSessionID = s.id
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [telemetry = lmTelemetry] _ in telemetry.stopSynchronously() }
        discovery.onDownloadFinished = { [weak self] in self?.refreshModels() }
        startAutoRefresh()
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        lmTelemetry.stopSynchronously()
    }

    // MARK: - Refresh

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(AppSettings.monitorInterval))
            }
        }
    }

    func refreshStatus() {
        Task { await refresh() }
    }

    func refreshModels() {
        guard !isManualRefreshing else { return }
        isManualRefreshing = true
        Task {
            defer { isManualRefreshing = false }
            // Un clic pendant une collecte de fond attend sa fin ; il n'est pas perdu.
            while isRefreshing {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            await refresh(manual: true)
        }
    }

    private func refresh(manual: Bool = false) async {
        guard !isRefreshing, (!isManualRefreshing || manual), !Task.isCancelled else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var issues: [String] = []
        var details: [String] = []

        async let ollamaConn = ollama.checkConnection()
        async let lmConn = lmStudio.checkConnection()
        async let ollamaModelsTask = refreshOllamaModels()
        async let lmModelsTask = refreshLMStudioLibrary()
        async let ollamaLoaded = refreshOllamaInstances()
        async let lmLoaded = refreshLMStudioInstances()
        async let openRouterTask = openRouter.freeModels()
        async let alibabaTask = alibaba.models()
        async let providerTask = CloudProviders.models()
        async let mlxInstances = mlxMonitor.scan()
        async let gatewayRequests = gateway.telemetrySnapshot()

        let oldModels = models
        let oldLibrary = refreshLibrarySnapshot(oldModels)
        let oldInstances = systemStatus?.activeInstances ?? []
        let om = await ollamaModelsTask
        let orResult: Result<[LLMModel], Error>
        do { orResult = .success(try await openRouterTask) } catch { orResult = .failure(error) }
        let alibabaModels = await alibabaTask
        let providerModels = await providerTask
        let lm = await lmModelsTask
        let oi = await ollamaLoaded
        let li = await lmLoaded
        let mlx = await mlxInstances
        guard !Task.isCancelled else { return }

        // Une source en échec conserve son dernier inventaire connu.
        let ollamaModels: [LLMModel]
        switch om {
        case .success(let value):
            ollamaModels = value
            details.append(L("Ollama / Cloud via /api/tags : %@ modèles reçus.", "\(value.count)"))
        case .failure(let error):
            ollamaModels = oldModels.filter { $0.source == .ollama || $0.source == .cloud }
            issues.append(L("Ollama / Cloud — bibliothèque : %@. Données précédentes conservées.", "\(error.localizedDescription)"))
        }
        let lmModels: [LLMModel]
        switch lm {
        case .success(let value):
            lmModels = value
            details.append(L("LM Studio : %@ modèles reçus (CLI ou repli HTTP).", "\(value.count)"))
        case .failure(let error):
            lmModels = oldModels.filter { $0.source == .lmStudio }
            issues.append(L("LM Studio — bibliothèque : %@. Données précédentes conservées.", "\(error.localizedDescription)"))
        }
        let openRouterModels: [LLMModel]
        switch orResult {
        case .success(let value):
            openRouterModels = value
            details.append(L("OpenRouter (gratuits) : %@ modèles reçus.", "\(value.count)"))
        case .failure(let error):
            openRouterModels = oldModels.filter { $0.source == .openRouter }
            issues.append(L("OpenRouter — catalogue : %@. Données précédentes conservées.", "\(error.localizedDescription)"))
        }
        details.append(alibabaModels.isEmpty
            ? L("Alibaba : aucun modèle (variable DASHSCOPE_API_KEY absente ou catalogue injoignable).")
            : L("Alibaba : %@ modèles reçus.", "\(alibabaModels.count)"))
        details.append(L("Fournisseurs cloud connectés : %@ modèles reçus.", "\(providerModels.count)"))
        var active = mlx
        switch oi {
        case .success(let value): active += value
        case .failure(let error):
            active += oldInstances.filter { $0.engine == .ollama }
            issues.append(L("Ollama — mémoire : %@. État précédent conservé.", "\(error.localizedDescription)"))
        }
        switch li {
        case .success(let value): active += value
        case .failure(let error):
            active += oldInstances.filter { $0.engine == .lmStudio }
            issues.append(L("LM Studio — mémoire : %@. État précédent conservé.", "\(error.localizedDescription)"))
        }
        // Le scan actuel masque les erreurs de ps/lsof : zéro résultat n'est pas
        // une preuve d'absence. Ne jamais annoncer un succès de toutes les sources.
        details.append(L("MLX direct : %@ instances détectées ; erreurs de ps/lsof non remontées, scan non vérifiable. Aucun inventaire MLX disque.", "\(mlx.count)"))
        details.append(L("Cloud : références Ollama uniquement ; disponibilité distante non vérifiée. Source inconnue : aucun collecteur."))
        details.append(L("CLI LM Studio : JSON validé, code de sortie non exposé par Shell. Capacités Ollama : enrichissement facultatif non vérifiable."))
        // Même modèle sur Ollama Cloud (glm-5.3:cloud ↔ alibaba/glm-5.3) : ses capacités déclarées par /api/show
        // complètent celles déduites pour Alibaba (qui n'en publie aucune ; Hugging Face ignore le raisonnement).
        let ollamaCapabilities = Dictionary(ollamaModels.map { (HuggingFaceFacts.key(String($0.id.split(separator: ":")[0])), $0.capabilities) },
                                            uniquingKeysWith: { $0 + $1 })
        let enrichedAlibaba = alibabaModels.map { model -> LLMModel in
            guard let extra = ollamaCapabilities[HuggingFaceFacts.key(model.id)] else { return model }
            var model = model
            for capability in extra where capability != "completion" && !model.capabilities.contains(capability) {
                model.capabilities.append(capability)
            }
            return model
        }
        self.models = (ollamaModels + lmModels + openRouterModels + enrichedAlibaba + providerModels + oldModels.filter { $0.source == .mlxDirect || $0.source == .unknown })
            .sorted { $0.name < $1.name }

        // Carry library metadata into memory cards when /api/ps omits MLX details.
        for index in active.indices {
            guard let model = LLMModel.libraryModel(for: active[index], in: models) else { continue }
            if LLMModel.parameterValue(active[index].params) == nil { active[index].params = model.parameters }
            if active[index].quantization?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                active[index].quantization = model.quantization
            }
        }

        // Diagnostics are attributed only to a unique exact runtime identifier.
        let groups = Dictionary(grouping: active.filter { $0.engine == .lmStudio }, by: \.modelName)
        let identifiers = Set(groups.filter { $0.value.count == 1 }.keys)
        let telemetry = await lmTelemetry.snapshot(activeIdentifiers: identifiers)
        telemetryExplanation = telemetry.explanation
        await lmTelemetry.start()
        for index in active.indices where active[index].engine == .lmStudio {
            active[index].lastPrediction = identifiers.contains(active[index].modelName)
                ? telemetry.predictions[active[index].modelName] : nil
            if identifiers.contains(active[index].modelName), let percent = telemetry.promptProgress[active[index].modelName] {
                active[index].processState = .processingPrompt
                active[index].processingPromptPercent = percent
            }
        }

        let gatewaySnapshot = await gatewayRequests
        GatewayActivity.apply(gatewaySnapshot.requests, calls: gatewaySnapshot.calls, to: &active)

        // Synchronise l'état de la bibliothèque avec les instances chargées
        // (colonne « Statut » + RAM : un modèle visible en Ollama/LM Studio/MLX
        //  porte le même nom, mais avec des conventions différentes → comparaison
        //  normalisée via ModelName).
        var activeByID: [String: ModelInstance] = [:]
        for instance in active {
            if let model = LLMModel.libraryModel(for: instance, in: models) { activeByID[model.id] = instance }
        }
        for i in self.models.indices {
            if let inst = activeByID[self.models[i].id] {
                self.models[i].isActive = true
                self.models[i].activeEngine = inst.engine
                self.models[i].activeRAM_MB = inst.ram_MB
            } else {
                self.models[i].isActive = false
                self.models[i].activeEngine = nil
                self.models[i].activeRAM_MB = 0
            }
        }

        let totalRAM = active.reduce(0) { $0 + $1.ram_MB }
        let warnings = await conflictDetector.detectConflicts(instances: active)

        let oc = await ollamaConn
        let lc = await lmConn
        self.systemStatus = SystemStatus(
            ollamaConnected: oc.0,
            ollamaVersion: oc.1,
            lmStudioConnected: lc.0,
            lmStudioVersion: lc.1,
            activeInstances: active,
            totalRAM_MB: totalRAM,
            conflicts: warnings,
            timestamp: Date()
        )
        refreshMemoryInfo()
        // Le suivi automatique de la mémoire ne remplace pas le résultat du
        // dernier clic manuel et ne fait pas clignoter la toolbar toutes les 2 s.
        if manual || !hasManualRefreshResult {
            refreshIssues = issues
            refreshDetails = details
            lastRefreshDate = Date()
            if manual {
                let changed = oldLibrary != refreshLibrarySnapshot(models)
                refreshSummary = changed ? L("Bibliothèque actualisée") : L("Bibliothèque inchangée")
                if case .failure = om, case .failure = lm {
                    refreshSummary = L("Bibliothèque non actualisée")
                }
                hasManualRefreshResult = true
                refreshDetails.insert(changed ? L("Inventaire modifié depuis le début de cette actualisation manuelle.")
                                             : L("Inventaire identique depuis le début de cette actualisation manuelle."), at: 0)
            } else {
                refreshSummary = L("Bibliothèque lue · %@ modèles", "\(models.count)")
            }
            if !issues.isEmpty { refreshSummary += " · \(issues.count) erreur(s), collecte partielle" }
            refreshDetails.insert(L("Lecture locale uniquement ; aucune recherche de mises à jour dans un registre."), at: 0)
            if !oc.0 { refreshDetails.append(L("API de connexion Ollama indisponible lors de cette collecte.")) }
            if !lc.0 { refreshDetails.append(L("Serveur HTTP LM Studio indisponible ; le CLI peut fonctionner indépendamment.")) }
        }
    }

    private func refreshLibrarySnapshot(_ models: [LLMModel]) -> Set<LLMModel> {
        Set(models.map { model in
            var value = model
            // Le chargement/RAM et l'ordre d'affichage ne changent pas la bibliothèque.
            value.isActive = false
            value.activeEngine = nil
            value.activeRAM_MB = 0
            value.capabilities.sort()
            return value
        })
    }

    // Les services renvoient [] pour une panne comme pour une bibliothèque vide.
    // Le refresh valide donc le statut HTTP et le décodage avant de remplacer les données.
    private func refreshData(baseURL: URL, path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Refresh", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "\(path) : HTTP \(status)"])
        }
        return data
    }

    private func refreshOllamaModels() async -> Result<[LLMModel], Error> {
        do {
            let data = try await refreshData(baseURL: AppSettings.ollamaBaseURL, path: "api/tags")
            let models = try OllamaService.decodeTags(data)
            return .success(await ollama.enrichModels(models))
        } catch { return .failure(error) }
    }

    private func refreshOllamaInstances() async -> Result<[ModelInstance], Error> {
        do {
            let data = try await refreshData(baseURL: AppSettings.ollamaBaseURL, path: "api/ps")
            return .success(try OllamaService.decodePS(data))
        } catch { return .failure(error) }
    }

    private func refreshLMSData(command: String) async throws -> Data {
        guard let lms = Shell.lmsPath(), let raw = await Shell.run(lms, [command, "--json"]),
              let data = raw.data(using: .utf8) else {
            throw NSError(domain: "Refresh", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("CLI lms %@ indisponible ou sans réponse", command)])
        }
        _ = try JSONDecoder().decode([LMStudioService.LMSModel].self, from: data)
        return data
    }

    private func refreshLMStudioLibrary() async -> Result<[LLMModel], Error> {
        do {
            let data = try await refreshLMSData(command: "ls")
            let entries = try JSONDecoder().decode([LMStudioService.LMSModel].self, from: data)
            let models = LMStudioService.decodeLibrary(from: data)
            guard models.count == entries.count else {
                throw NSError(domain: "Refresh", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: L("CLI lms ls : modèle sans identifiant")])
            }
            return .success(models)
        } catch {
            let cliError = error.localizedDescription
            do {
                let data = try await refreshData(baseURL: AppSettings.lmStudioBaseURL, path: "api/v0/models")
                let list = try JSONDecoder().decode(RefreshLMList.self, from: data)
                return .success(list.data.map { model in
                    var caps = [String]()
                    if model.type == "vlm" { caps.append("vision") }
                    if model.capabilities?.contains("tool_use") == true { caps.append("tools") }
                    return LLMModel(id: model.id, name: model.id, parameters: nil,
                                    quantization: model.quantization, sizeBytes: 0,
                                    capabilities: caps, modified: nil, source: .lmStudio)
                })
            } catch {
                return .failure(NSError(domain: "Refresh", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "\(cliError) ; repli HTTP : \(error.localizedDescription)"
                ]))
            }
        }
    }

    private func refreshLMStudioInstances() async -> Result<[ModelInstance], Error> {
        do {
            let data = try await refreshLMSData(command: "ps")
            let entries = try JSONDecoder().decode([LMStudioService.LMSModel].self, from: data)
            guard entries.allSatisfy({ $0.identifier != nil || $0.modelKey != nil || $0.displayName != nil }) else {
                throw NSError(domain: "Refresh", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "CLI lms ps : instance sans identifiant"])
            }
            return .success(LMStudioService.decodeInstances(from: data))
        } catch {
            let cliError = error.localizedDescription
            do {
                let data = try await refreshData(baseURL: AppSettings.lmStudioBaseURL, path: "api/v0/models")
                let list = try JSONDecoder().decode(RefreshLMList.self, from: data)
                // Sans state, une liste vide d'instances serait un faux négatif.
                guard list.data.allSatisfy({ $0.state != nil }) else {
                    throw NSError(domain: "Refresh", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: L("État mémoire absent de la réponse LM Studio")])
                }
                return .success(list.data.filter { $0.state == "loaded" }.map { model in
                    ModelInstance(modelName: model.id, engine: .lmStudio, ram_MB: 0,
                                  pid: nil, loadedAt: Date(), status: .active,
                                  typeLabel: model.type, vision: model.type == "vlm" ? true : nil,
                                  tools: model.capabilities?.contains("tool_use") == true ? true : nil,
                                  quantization: model.quantization)
                })
            } catch {
                return .failure(NSError(domain: "Refresh", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "\(cliError) ; repli HTTP : \(error.localizedDescription)"
                ]))
            }
        }
    }

    private struct RefreshLMList: Decodable {
        let data: [Entry]
        struct Entry: Decodable {
            let id: String
            let type: String?
            let quantization: String?
            let state: String?
            let capabilities: [String]?
        }
    }

    /// Info lisible de la RAM système + usage modèles.
    func refreshMemoryInfo() {
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let usedMB = systemStatus?.totalRAM_MB ?? 0
        systemMemoryInfo = String(format: L("%.1f Go modèles · %.0f Go système"),
                                  usedMB / 1024, totalGB)
    }

    // MARK: - Modèles

    func loadModel(_ model: LLMModel) {
        errorMessage = nil
        switch model.source {
        case .ollama:
            Task { try? await ollama.loadModel(id: model.id); await refresh() }
        case .lmStudio:
            Task { try? await lmStudio.loadModel(id: model.id); await refresh() }
        case .mlxDirect, .cloud, .openRouter, .alibaba, .provider, .unknown:
            break
        }
    }

    func deleteModel(_ model: LLMModel) {
        guard model.source == .ollama else { return }
        Task { try? await ollama.deleteModel(name: model.id); await refresh() }
    }

    // MARK: - Déchargement

    /// Éjecte une instance précise (bouton « Éjecter » de la vue En mémoire).
    func unload(_ instance: ModelInstance) {
        switch instance.engine {
        case .ollama:
            Task { try? await ollama.unloadModel(id: instance.modelName); await refresh() }
        case .lmStudio:
            Task { try? await lmStudio.unloadModel(identifier: instance.modelName); await refresh() }
        case .mlxDirect:
            if let pid = instance.pid { Task { await mlxMonitor.kill(pid: pid); await refresh() } }
        case .cloud, .openRouter, .alibaba, .provider, .unknown:
            break
        }
    }

    /// Éjecte tous les modèles d'un moteur (boutons « tout décharger »).
    func unloadFrom(_ source: LLMModel.ModelSource) {
        switch source {
        case .ollama:
            Task { try? await ollama.unloadAll(); await refresh() }
        case .lmStudio:
            Task { try? await lmStudio.unloadAll(); await refresh() }
        default:
            break
        }
    }

    // MARK: - Chat

    func newChat() {
        let s = ChatSession()
        chatSessions.insert(s, at: 0)
        currentSessionID = s.id
        selectedModelForChat = nil
        chatDraft = ""
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let modelID = selectedModelForChat else {
            errorMessage = L("Choisissez d'abord un modèle.")
            return
        }
        chatDraft = ""
        let sessionID = currentSessionID
        let userMsg = ChatMessage(role: "user", content: trimmed)
        if let i = chatSessions.firstIndex(where: { $0.id == sessionID }) {
            chatSessions[i].messages.append(userMsg)
        }
        isBusy = true
        Task {
            do {
                let history = currentSession?.messages ?? [userMsg]
                let reply: String
                switch selectedEngine {
                case .lmStudio:
                    reply = try await lmStudio.chat(messages: history, model: modelID)
                default:
                    reply = try await ollama.chat(messages: history, model: modelID)
                }
                if let i = chatSessions.firstIndex(where: { $0.id == sessionID }) {
                    chatSessions[i].messages.append(ChatMessage(role: "assistant", content: reply))
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isBusy = false
        }
    }
}
