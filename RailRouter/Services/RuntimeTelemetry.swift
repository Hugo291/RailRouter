import Foundation

/// Termination notifications cannot wait for actor hops. Only the process handle
/// crosses that boundary, guarded by a lock; actor-owned statistics stay isolated.
private final class TelemetryProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let child = process
        process = nil
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }

    deinit { terminate() }
}

/// Measured statistics for ONE completed prediction, never live counters or totals.
/// Schema: installed @lmstudio/sdk DiagnosticsLogOutputEventData / LLMPredictionStats.
struct PredictionTelemetry: Equatable, Sendable {
    let completedAt: Date
    let promptTokens: Int?
    let generatedTokens: Int?
    let tokensPerSecond: Double?
    var source = "LM Studio · flux lms"

    static func decodeLMStudioLog(_ line: Data) -> (identifier: String, stats: Self)? {
        struct Event: Decodable {
            let timestamp: Double
            let data: Output
            struct Output: Decodable {
                let type: String
                let modelIdentifier: String
                let stats: Stats?
            }
            struct Stats: Decodable {
                let promptTokensCount: Int?
                let predictedTokensCount: Int?
                let tokensPerSecond: Double?
            }
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: line),
              event.timestamp.isFinite, event.timestamp > 0,
              event.data.type == "llm.prediction.output",
              !event.data.modelIdentifier.isEmpty, let stats = event.data.stats else { return nil }
        let prompt = stats.promptTokensCount.flatMap { $0 >= 0 ? $0 : nil }
        let generated = stats.predictedTokensCount.flatMap { $0 >= 0 ? $0 : nil }
        let speed = stats.tokensPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard prompt != nil || generated != nil || speed != nil else { return nil }
        return (event.data.modelIdentifier, Self(
            completedAt: Date(timeIntervalSince1970: event.timestamp / 1000),
            promptTokens: prompt, generatedTokens: generated, tokensPerSecond: speed
        ))
    }
}

/// Progression du prompt publiée par LM Studio sur le flux `server` (« Prompt processing progress: 53.9% »).
/// C'est la source qu'utilise l'interface de LM Studio : `lms ps` ne la donne pas, le flux `model` non plus.
enum PromptProgress {
    static func decode(_ line: Data) -> (identifier: String, percent: Double)? {
        struct Event: Decodable {
            let data: Content
            struct Content: Decodable { let type: String; let content: String? }
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: line),
              event.data.type == "server.log", let content = event.data.content,
              let range = content.range(of: "Prompt processing progress: ") else { return nil }
        let head = content[..<range.lowerBound]
        guard head.hasSuffix("] "), let open = head.dropLast(2).lastIndex(of: "["),
              let percent = Double(content[range.upperBound...].prefix { $0.isNumber || $0 == "." }),
              percent.isFinite, (0...100).contains(percent) else { return nil }
        let identifier = String(head[head.index(after: open)...].dropLast(2))
        return identifier.isEmpty ? nil : (identifier, percent)
    }
}

/// Passive observer: never loads a model or initiates inference.
/// lms diagnostics delivers output once a prediction completes (including external clients).
/// Prompts/output text are discarded; only measured metadata is retained for five minutes.
actor LMStudioTelemetry {
    private nonisolated let lifetime = TelemetryProcessLifetime()
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var buffer = Data()
    private var droppingOversizedLine = false
    private var activeIdentifiers: Set<String> = []
    private var latest: [String: PredictionTelemetry] = [:]
    private var promptProgress: [String: (percent: Double, at: Date)] = [:]
    private var explanation = L("Aucune statistique observée depuis le début du suivi.")
    private var nextRetryAt = Date.distantPast
    private var retryDelay: TimeInterval = 2

    /// Use from NSApplication.willTerminateNotification (no Task/await required).
    /// The shell watchdog also cleans up after abrupt parent termination.
    nonisolated func stopSynchronously() { lifetime.terminate() }

    // Positional arguments keep paths out of shell source. The watchdog is required:
    // Process children otherwise survive termination of the macOS app.
    static let observerScript = """
    parent_pid=$1
    lms_path=$2
    "$lms_path" log stream --source model --filter output --json &
    lms_pid=$!
    "$lms_path" log stream --source server --json &
    srv_pid=$!
    (
      while kill -0 "$parent_pid" 2>/dev/null; do sleep 1; done
      kill -TERM "$lms_pid" "$srv_pid" 2>/dev/null
    ) &
    watch_pid=$!
    cleanup() {
      trap - EXIT TERM INT
      kill -TERM "$lms_pid" "$srv_pid" "$watch_pid" 2>/dev/null || true
      wait "$lms_pid" "$srv_pid" "$watch_pid" 2>/dev/null || true
    }
    trap cleanup EXIT
    trap 'exit 0' TERM INT
    wait "$lms_pid"
    exit $?
    """

    struct Snapshot: Sendable {
        let predictions: [String: PredictionTelemetry]
        let explanation: String
        var promptProgress: [String: Double] = [:]
    }

    func start() {
        guard process == nil, Date() >= nextRetryAt else { return }
        guard let path = Shell.lmsPath() else {
            scheduleRetry("Statistiques indisponibles : CLI lms introuvable.")
            return
        }
        let child = Process()
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", Self.observerScript, "jedi-telemetry", String(ProcessInfo.processInfo.processIdentifier), path]
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            scheduleRetry(L("Statistiques indisponibles : impossible d’ouvrir le flux lms."))
            return
        }
        process = child
        lifetime.install(child)
        generation = UUID()
        let currentGeneration = generation
        explanation = L("Aucune statistique observée depuis le début du suivi.")
        // A single reader preserves chunk order. Terminating the child unblocks reads.
        reader = Task.detached(priority: .utility) { [weak self] in
            let handle = pipe.fileHandleForReading
            defer { try? handle.close() }
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                await self?.consume(chunk, generation: currentGeneration)
            }
            await self?.streamEnded(generation: currentGeneration)
        }
    }

    func stop() {
        generation = UUID()
        reader?.cancel()
        reader = nil
        lifetime.terminate()
        process = nil
        buffer.removeAll()
        droppingOversizedLine = false
        latest.removeAll()
        promptProgress.removeAll()
        activeIdentifiers.removeAll()
        nextRetryAt = .distantPast
        retryDelay = 2
    }

    func snapshot(activeIdentifiers: Set<String>, now: Date = Date()) -> Snapshot {
        self.activeIdentifiers = activeIdentifiers
        latest = latest.filter {
            activeIdentifiers.contains($0.key) && now.timeIntervalSince($0.value.completedAt) <= 300
        }
        promptProgress = promptProgress.filter { activeIdentifiers.contains($0.key) && now.timeIntervalSince($0.value.at) <= 20 }
        return Snapshot(predictions: latest, explanation: explanation,
                        promptProgress: promptProgress.filter { $0.value.percent < 100 }.mapValues(\.percent))
    }

    /// Internal for deterministic chunked-NDJSON tests, without launching any runtime.
    func ingest(_ chunk: Data, now: Date = Date()) {
        // Bound a single log line to 8 MiB, discard oversized output rather than infer tokens.
        for byte in chunk {
            if byte == 10 {
                if !droppingOversizedLine, let progress = PromptProgress.decode(buffer) {
                    promptProgress[progress.identifier] = (progress.percent, now)
                } else if !droppingOversizedLine,
                   let event = PredictionTelemetry.decodeLMStudioLog(buffer),
                   activeIdentifiers.contains(event.identifier),
                   event.stats.completedAt <= now,
                   now.timeIntervalSince(event.stats.completedAt) <= 300,
                   latest[event.identifier].map({ $0.completedAt <= event.stats.completedAt }) ?? true {
                    latest[event.identifier] = event.stats
                    retryDelay = 2
                }
                buffer.removeAll(keepingCapacity: false)
                droppingOversizedLine = false
            } else if !droppingOversizedLine {
                if buffer.count < 8 * 1024 * 1024 { buffer.append(byte) }
                else {
                    buffer.removeAll(keepingCapacity: false)
                    droppingOversizedLine = true
                }
            }
        }
    }

    private func consume(_ chunk: Data, generation: UUID) {
        guard generation == self.generation else { return }
        ingest(chunk)
    }

    private func streamEnded(generation: UUID) {
        guard generation == self.generation else { return }
        process = nil
        reader = nil
        buffer.removeAll()
        latest.removeAll()
        scheduleRetry(L("Statistiques indisponibles : le flux lms est déconnecté."))
    }

    private func scheduleRetry(_ reason: String) {
        nextRetryAt = Date().addingTimeInterval(retryDelay)
        explanation = L("%@ Nouvelle tentative dans %lld s.", reason, Int(retryDelay))
        retryDelay = min(60, retryDelay * 2)
    }
}
