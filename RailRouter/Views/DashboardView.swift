import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusHeaderView(status: modelManager.systemStatus)

                if let status = modelManager.systemStatus, status.hasConflicts {
                    ForEach(status.conflicts) { warning in
                        ConflictBanner(warning: warning)
                    }
                }

                ActiveModelsView()
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L("Tableau de bord"))
        .toolbar {
            Button {
                Task { await modelManager.refreshStatus() }
            } label: {
                Label(L("Actualiser"), systemImage: "arrow.clockwise")
            }
        }
    }
}

struct StatusHeaderView: View {
    let status: SystemStatus?

    var body: some View {
        HStack(spacing: 16) {
            engineCard("Ollama", isOn: status?.ollamaConnected ?? false, version: status?.ollamaVersion)
            engineCard("LM Studio", isOn: status?.lmStudioConnected ?? false, version: status?.lmStudioVersion)

            VStack(alignment: .leading, spacing: 6) {
                Label(L("RAM modèles"), systemImage: "memorystick")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(ramText)
                    .font(.title2.bold())
                Text(L("%lld instance(s) active(s)", status?.activeInstances.count ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var ramText: String {
        let mb = status?.totalRAM_MB ?? 0
        if mb >= 1024 { return String(format: "%.1f Go", mb / 1024) }
        return String(format: "%.0f Mo", mb)
    }

    private func engineCard(_ name: String, isOn: Bool, version: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Circle()
                    .fill(isOn ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
            }
            Text(isOn ? (version.map { "v\($0)" } ?? L("connecté")) : L("hors ligne"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ConflictBanner: View {
    let warning: SystemStatus.ConflictWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: warning.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(warning.severity == .critical ? .red : .orange)
                Text(L("Double chargement: %@", warning.modelName))
                    .font(.headline)
                Spacer()
                Text(warning.severity == .critical ? L("CRITIQUE") : L("AVERTISSEMENT"))
                    .font(.caption.bold())
                    .foregroundStyle(warning.severity == .critical ? .red : .orange)
            }
            Text(warning.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            warning.severity == .critical ? Color.red.opacity(0.12) : Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(warning.severity == .critical ? Color.red.opacity(0.5) : Color.orange.opacity(0.5))
        )
    }
}

struct ActiveModelsView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Modèles chargés en mémoire"))
                .font(.title3.bold())

            if let instances = modelManager.systemStatus?.activeInstances, !instances.isEmpty {
                ForEach(instances) { instance in
                    instanceRow(instance)
                }
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L("Aucun modèle actif"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func instanceRow(_ instance: ModelInstance) -> some View {
        HStack(spacing: 12) {
            Image(systemName: instance.engine.systemImage)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.modelName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(instance.processState == .unknown
                     ? instance.status.rawValue
                     : instance.processState.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(instance.processState.isBusy ? .orange : .secondary)
            }

            Spacer()

            Text(instance.engine.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            if instance.ram_MB > 0 {
                Text(String(format: "%.0f Mo", instance.ram_MB))
                    .font(.callout.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
            }

            if let pid = instance.pid {
                Text("pid \(pid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }

            if instance.engine == .lmStudio || instance.engine == .ollama || instance.engine == .mlxDirect {
                Button {
                    modelManager.unload(instance)
                } label: {
                    Image(systemName: "power")
                }
                .help(L("Éjecter ce modèle"))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
