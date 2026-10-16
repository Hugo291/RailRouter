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

    /// stable-diffusion.cpp (`sd-cli`, `sd-server`) : l'exécutable, ou toute bibliothèque `libstable-diffusion.dylib` chargée
    /// (`dylibPIDs`, via lsof). Ni Python ni « mlx » dans la ligne de commande : `scanMLXProcesses` ne les voit pas.
    static func scanStableDiffusionProcesses(in all: [MLXProcessInfo], dylibPIDs: Set<Int> = []) -> [MLXProcessInfo] {
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        return all.filter { info in
            guard info.pid != selfPID else { return false }
            let exe = ((info.commandLine.split(separator: " ").first.map(String.init) ?? "") as NSString).lastPathComponent
            return ["sd-cli", "sd-server"].contains(exe) || dylibPIDs.contains(info.pid)
        }
    }

    /// Une passe `lsof` : fichiers .safetensors encore ouverts, et processus qui ont
    /// chargé `libmlx.dylib` (ou `libstable-diffusion.dylib`, sd.cpp). MLX lit les poids puis ferme les fichiers : un script
    /// Python qui importe mlx (`python bench.py`) n'a ni preuve dans sa ligne de
    /// commande ni .safetensors ouvert une fois chargé — seule la bibliothèque reste
    /// mappée (Clef 27B via mlx-vlm, 09/10/2026).
    static func lsofMLX() -> (safetensors: [SafetensorsEntry], mlxPIDs: Set<Int>, sdPIDs: Set<Int>) {
        guard let output = run("/usr/sbin/lsof", ["-w", "-Fn"]) else { return ([], [], []) }
        return parseLsof(output, selfPID: Int(ProcessInfo.processInfo.processIdentifier))
    }

    /// Décode la sortie `lsof -Fn` (internal : tests unitaires).
    static func parseLsof(_ output: String, selfPID: Int) -> (safetensors: [SafetensorsEntry], mlxPIDs: Set<Int>, sdPIDs: Set<Int>) {
        var safetensors: [SafetensorsEntry] = []
        var mlxPIDs = Set<Int>(), sdPIDs = Set<Int>()
        var currentPID: Int? = nil
        for line in output.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            if first == "p" { currentPID = Int(line.dropFirst()); continue }
            guard first == "n", let pid = currentPID, pid != selfPID else { continue }
            let path = String(line.dropFirst())
            if path.hasSuffix(".safetensors") {
                safetensors.append(SafetensorsEntry(pid: pid, filePath: path))
            } else if path.hasSuffix("/libmlx.dylib") {
                mlxPIDs.insert(pid)
            } else if path.hasSuffix("/libstable-diffusion.dylib") {
                sdPIDs.insert(pid)
            }
        }
        return (safetensors, mlxPIDs, sdPIDs)
    }

    /// Empreinte physique en Mo, celle du Moniteur d'activité. La RSS de `ps` ignore
    /// la mémoire GPU (Metal) où MLX range les poids : 1,0 Go de RSS pour 15,4 Go
    /// d'empreinte sur Clef 27B 4 bits (mesuré le 09/10/2026).
    static func footprintMB(pid: Int) -> Double? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid_t(pid), RUSAGE_INFO_V2, $0)
            }
        }
        return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
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
