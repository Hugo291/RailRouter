import Foundation

/// Petit utilitaire pour appeler des binaires système (lms, ps, lsof, …).
enum Shell {

    /// Chemin du CLI `lms` de LM Studio (installé dans le dossier utilisateur).
    static func lmsPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".lmstudio/bin/lms").path,
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `lms` seulement si l'app LM Studio ou le démon `llmster` tourne déjà : le CLI démarre
    /// sinon `llmster` lui-même, et LM Studio refuse ensuite de s'ouvrir (« cannot run at the same time »).
    /// Pour les lectures périodiques ; une action explicite de l'utilisateur utilise `lmsPath()`.
    static func lmsPathIfRunning() -> String? {
        guard let path = lmsPath(), runSync("/usr/bin/pgrep", ["-x", "LM Studio|llmster"], timeout: 3) != nil else { return nil }
        return path
    }

    /// Exécute `path args…` et renvoie stdout (nil si échec/lancement impossible). Non bloquant.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) async -> String? {
        await withCheckedContinuation { cont in
            Task.detached {
                let out = runSync(path, args, timeout: timeout)
                cont.resume(returning: out)
            }
        }
    }

    /// Version synchrone — lire stdout jusqu'à EOF, avec timeout de sécurité.
    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return nil }

        // Timeout de sécurité : terminer si le process ne se termine pas.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning { proc.terminate() }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: outData, encoding: .utf8)
        let err = String(data: errData, encoding: .utf8)
        // Si la sortie est vide, renvoyer nil (échec).
        guard let out, !out.isEmpty else { return nil }
        if let err, !err.isEmpty { return out + "\n" + err }
        return out
    }
}
