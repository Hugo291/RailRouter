import Foundation
import Combine
import AppKit

@MainActor
final class GatewayController: ObservableObject {
    static let port: UInt16 = 41235
    static let label = "local.TchouTchou.gateway"
    static let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var message = L("Endpoint non démarré")
    @Published private(set) var modelIDs: [String] = []
    @Published private(set) var catalogMessage = ""
    @Published private(set) var requests: [GatewayRequestTelemetry] = []
    var catalogPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TchouTchou/codex-catalog.json").path }
    var apiURL: String { Self.baseURL.appendingPathComponent("v1").absoluteString }
    private var domain: String { "gui/\(getuid())" }
    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    func refresh() async {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["service"] as? String)?.contains("TchouTchou") == true else {
                running = false
                message = L("Port %@ occupé par un service non identifié. Aucun remplacement effectué.", "\(Self.port)")
                return
            }
            running = true
            if !busy { message = L("Endpoint local actif · service indépendant de la fenêtre") }
            var modelsRequest = URLRequest(url: Self.baseURL.appendingPathComponent("v1/models"))
            modelsRequest.timeoutInterval = 5
            if let (models, response) = try? await URLSession.shared.data(for: modelsRequest),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: models) as? [String: Any],
               let values = json["data"] as? [[String: Any]] {
                modelIDs = values.compactMap { $0["id"] as? String }.sorted()
            }
        } catch {
            running = false
            modelIDs = []
            if !busy { message = L("Endpoint arrêté ou indisponible") }
        }
    }

    func telemetrySnapshot() async -> [GatewayRequestTelemetry] {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("telemetry"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        struct Envelope: Decodable { let requests: [GatewayRequestTelemetry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let values = (try? decoder.decode(Envelope.self, from: data).requests) ?? []
        requests = values
        return values
    }

    func start() {
        guard !busy else { return }
        busy = true
        message = L("Installation du service local…")
        Task {
            defer { busy = false }
            do {
                let executable = "/Applications/TchouTchou.app/Contents/MacOS/TchouTchou"
                guard FileManager.default.isExecutableFile(atPath: executable) else {
                    throw NSError(domain: "Gateway", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Installez TchouTchou dans Applications.")])
                }
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TchouTchou")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": Self.label,
                    "ProgramArguments": [executable, "--serve-gateway", "--port", String(Self.port)],
                    "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
                    "StandardErrorPath": directory.appendingPathComponent("gateway.log").path,
                    "StandardOutPath": directory.appendingPathComponent("gateway.log").path,
                    "ProcessType": "Background"
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: agentURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentURL.path)
                // Bootstrap does not replace any other label/port, especially the active Codex router.
                _ = await Shell.run("/bin/launchctl", ["bootstrap", domain, agentURL.path])
                _ = await Shell.run("/bin/launchctl", ["kickstart", domain + "/" + Self.label])
                for _ in 0..<20 {
                    await refresh()
                    if running { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                message = running ? L("Endpoint prêt · aucun modèle supplémentaire chargé") : L("Démarrage non confirmé : consultez le journal du service.")
            } catch { message = error.localizedDescription }
        }
    }

    func stop() {
        guard !busy else { return }
        busy = true
        Task {
            _ = await Shell.run("/bin/launchctl", ["bootout", domain + "/" + Self.label])
            await refresh()
            message = running ? L("Le service n’a pas pu être arrêté.") : L("Service arrêté. Les modèles et l’ancien routeur restent inchangés.")
            busy = false
        }
    }

    func exportCodexCatalog() {
        Task {
            do {
                let previous = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/local-models/catalog.json")
                let data = try Data(contentsOf: previous)
                guard data.count <= 8 * 1024 * 1024,
                      var catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var models = catalog["models"] as? [[String: Any]],
                      let template = models.first(where: { ($0["slug"] as? String)?.lowercased().contains("qwen3.8") == true && ($0["description"] as? String)?.contains("LM Studio") == true }) else {
                    throw NSError(domain: "Gateway", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Catalogue Codex ou modèle de référence Qwen3.8 introuvable.")])
                }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8090/health")!)
                request.timeoutInterval = 2
                let (healthData, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let health = try JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                      let model = health["loaded_model"] as? String,
                      let context = health["effective_context_limit"] as? Int, context > 0,
                      model.lowercased().contains("qwen3.8"), modelIDs.contains("mlx/" + model) else {
                    throw NSError(domain: "Gateway", code: 3, userInfo: [NSLocalizedDescriptionKey: L("Aucun Qwen3.8 MLX servi n’a été confirmé.")])
                }
                let id = "mlx/" + model
                models.removeAll { $0["slug"] as? String == id }
                var entry = template
                entry["slug"] = id
                entry["display_name"] = "MLX · " + model
                entry["description"] = "MLX direct via TchouTchou (local)"
                entry["context_window"] = context
                entry["max_context_window"] = context
                entry["auto_compact_token_limit"] = Int(Double(context) * 0.8)
                models.append(entry)
                catalog["models"] = models
                let output = URL(fileURLWithPath: catalogPath)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
                catalogMessage = L("Catalogue créé avec %@ entrées, dont ton Qwen3.8 MLX. Aucun fichier Codex remplacé.", "\(models.count)")
            } catch { catalogMessage = error.localizedDescription }
        }
    }

    func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiURL, forType: .string)
    }
}
