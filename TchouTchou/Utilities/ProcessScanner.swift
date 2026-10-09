import Foundation

/// Scanne les processus du système pour détecter les modèles MLX lancés
/// hors LM Studio / Ollama (via mlx_lm, mlx_server, scripts python, etc.).
actor ProcessScanner {

    /// Exécutables qui ne sont JAMAIS un vrai moteur MLX (shells, runtimes, CLI) —
    /// on les exclut même si le mot "mlx" apparaît dans leurs arguments.
    private static let excludedExecs: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "csh", "ksh", "tmux", "screen",
        "node", "npm", "npx", "yarn", "pnpm", "bun", "deno",
        "lms", "lldb", "top", "htop"
    ]
    /// Preuves d'un vrai usage MLX dans la ligne de commande.
    private static let mlxEvidence = [
        "mlx_lm", "mlx-lm", "mlx_vlm", "mlx-vlm", "-m mlx", "mlx.utils", "mlx_server",
        "mlx-server", "mlx_cpp", "mlx_lm.", "mlx-lm/", "safetensors"
    ]

    /// Lister tous les processus (pid, ligne de commande, RSS en Mo)
    static func allProcesses() -> [MLXProcessInfo] {
        guard let output = run("/bin/ps", ["-axo", "pid=,rss=,command="]) else { return [] }
        var result: [MLXProcessInfo] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 3, let pid = Int(fields[0]) else { continue }
            let rssKB = Double(fields[1]) ?? 0

            let info = MLXProcessInfo(pid: pid, commandLine: fields[2], ramUsage_MB: rssKB / 1024.0)
            result.append(info)
        }
        return result
    }

    /// Processus qui chargent/exécutent réellement un modèle MLX.
    /// Robuste : exige un exécutable Python (ou un binaire "mlx*") AVEC une preuve
    /// MLX dans la ligne de commande. Élimine les faux positifs (zsh, lms, node…).
    static func scanMLXProcesses() -> [MLXProcessInfo] {
        scanMLXProcesses(in: allProcesses())
    }

    /// Version sur une liste pré-fétchée (évite un second `ps` quand
    /// `allProcesses()` vient d'être appelée).
    static func scanMLXProcesses(in all: [MLXProcessInfo]) -> [MLXProcessInfo] {
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        let selfName = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "").lowercased()
        return all.filter { info in
            guard info.pid != selfPID else { return false }
            let cmd = info.commandLine
            let lower = cmd.lowercased()
            guard let spaceIdx = cmd.firstIndex(of: " ") else {
                // Token unique : un binaire mlx_* direct ?
                let exe = ((cmd as NSString).lastPathComponent).lowercased()
                return exe.contains("mlx") && !Self.excludedExecs.contains(exe)
            }
            let exe = ((String(cmd[cmd.startIndex..<spaceIdx]) as NSString).lastPathComponent).lowercased()

            if exe == selfName { return false }
            if Self.excludedExecs.contains(exe) { return false }

            let hasEvidence = Self.mlxEvidence.contains { lower.contains($0) }

            if exe.hasPrefix("python") { return hasEvidence }      // python3 script.py … → preuve requise
            if exe.contains("mlx") { return true }                // binaire mlx_* → OK
            return false
        }
    }

    /// Fichiers .safetensors ouverts par un processus (lsof)
    static func openSafetensorsFiles() -> [SafetensorsEntry] {
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        guard let output = run("/usr/sbin/lsof", ["-w", "-Fn"]) else { return [] }
        var result: [SafetensorsEntry] = []

        var currentPID: Int? = nil
        for line in output.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPID = Int(line.dropFirst())
            case "n":
                let path = String(line.dropFirst())
                if path.hasSuffix(".safetensors"), let pid = currentPID, pid != selfPID {
                    result.append(SafetensorsEntry(pid: pid, filePath: path))
                }
            default:
                break
            }
        }
        return result
    }

    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
