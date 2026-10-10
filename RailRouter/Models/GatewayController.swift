import Foundation
import Combine
import AppKit

@MainActor
final class GatewayController: ObservableObject {
    static let port: UInt16 = 41235
    static let label = "local.RailRouter.gateway"
    static let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var message = L("Endpoint non démarré")
    @Published private(set) var modelIDs: [String] = []
    @Published private(set) var requests: [GatewayRequestTelemetry] = []
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
                  (json["service"] as? String)?.contains("RailRouter") == true else {
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

    func telemetrySnapshot() async -> (requests: [GatewayRequestTelemetry], calls: [String: Int]) {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("telemetry"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return ([], [:]) }
        struct Envelope: Decodable { let requests: [GatewayRequestTelemetry]; let calls: [String: Int]? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let envelope = try? decoder.decode(Envelope.self, from: data)
        requests = envelope?.requests ?? []
        return (requests, envelope?.calls ?? [:])
    }

    func start() {
        guard !busy else { return }
        busy = true
        message = L("Installation du service local…")
        Task {
            defer { busy = false }
            do {
                let executable = "/Applications/RailRouter.app/Contents/MacOS/RailRouter"
                guard FileManager.default.isExecutableFile(atPath: executable) else {
                    throw NSError(domain: "Gateway", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Installez RailRouter dans Applications.")])
                }
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RailRouter")
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

    func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiURL, forType: .string)
    }
}
