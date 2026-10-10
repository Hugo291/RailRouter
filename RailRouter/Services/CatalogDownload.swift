import Foundation

struct CatalogDownloadProgress {
    let message: String
    let fraction: Double?
}

/// Downloads into the selected engine only. Never loads weights into memory.
enum CatalogDownload {
    static func run(entry: CatalogEntry, option: CatalogDownloadOption,
                    update: @escaping @Sendable (CatalogDownloadProgress) -> Void) async throws {
        switch entry.source {
        case .ollama:
            var request = URLRequest(url: AppSettings.ollamaBaseURL.appendingPathComponent("api/pull"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": option.downloadID, "stream": true])
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 86400
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure(L("Ollama a refusé le téléchargement."))
            }
            var succeeded = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let error = object["error"] as? String { throw failure(error) }
                let status = object["status"] as? String ?? L("Téléchargement…")
                let total = (object["total"] as? NSNumber)?.doubleValue ?? 0
                let completed = (object["completed"] as? NSNumber)?.doubleValue ?? 0
                let fraction = total > 0 ? min(1, max(0, completed / total)) : nil
                update(.init(message: status, fraction: fraction))
                succeeded = status == "success" || succeeded
            }
            guard succeeded else { throw failure(L("Téléchargement interrompu avant la confirmation d’Ollama.")) }
        case .lmStudio:
            guard let lms = Shell.lmsPath() else { throw failure(L("Installez le CLI lms depuis LM Studio pour télécharger.")) }
            let flag = entry.format.uppercased() == "MLX" ? "--mlx" : "--gguf"
            // A full Hugging Face URL fixes the repository/file, not a fuzzy staff-pick search.
            try await runCLI(lms, arguments: ["get", flag, "--yes", option.downloadID], update: update)
        case .all: throw failure("Choisissez Ollama ou LM Studio.")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CatalogDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func runCLI(_ path: String, arguments: [String],
                               update: @escaping @Sendable (CatalogDownloadProgress) -> Void) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            // One pipe avoids stdout/stderr deadlocks during long downloads.
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 86400) {
                if process.isRunning { process.terminate() }
            }
            var tail = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                tail = String((tail + text).suffix(4000))
                let clean = text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
                let last = clean.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                update(.init(message: last ?? L("Téléchargement LM Studio…"), fraction: nil))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw failure(L("LM Studio : %@", tail.isEmpty ? L("échec du téléchargement") : tail))
            }
        }.value
    }
}
