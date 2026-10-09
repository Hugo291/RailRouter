import SwiftUI

/// Sidebar façon Ollama GUI : sections, badges de compte, pied de statut
struct SidebarView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppIconView(size: 28)
                Text(L("TchouTchou")).font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 3) {
                sectionHeader(L("Bibliothèque"))
                item(.models, title: L("Modèles"), icon: "square.stack.3d.up", count: modelManager.models.count)
                item(.memory, title: L("En mémoire"), icon: "memorychip", count: modelManager.systemStatus?.activeInstances.count ?? 0)

                sectionHeader(L("Explorer"))
                item(.discover, title: L("Découvrir"), icon: "sparkle.magnifyingglass", count: nil)
                item(.gateway, title: "Endpoint", icon: "network", count: nil)
            }
            .padding(10)

            Spacer()

            statusFooter
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
        .padding(.leading, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 12)
            .padding(.top, 8)
    }

    private func item(_ section: AppSection, title: String, icon: String, count: Int?) -> some View {
        let selected = modelManager.selectedSection == section
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
            Spacer()
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .white : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? .white : .primary)
        .background(
            selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { modelManager.selectedSection = section }
        .accessibilityAddTraits(.isButton)
    }

    /// Réglages : pour l'instant, la langue de l'interface.
    private var settingsMenu: some View {
        Menu {
            Picker(L("Langue"), selection: $modelManager.language) {
                ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Réglages et langue de l'interface"))
        .accessibilityLabel(L("Réglages"))
    }

    private var statusFooter: some View {
        let ollamaUp = modelManager.systemStatus?.ollamaConnected ?? false
        let lmUp = modelManager.systemStatus?.lmStudioConnected ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ollamaUp ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(ollamaUp
                     ? L("Connecté · Ollama %@", modelManager.systemStatus?.ollamaVersion ?? "")
                     : L("Ollama hors ligne"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(lmUp ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(lmUp ? L("Connecté · LM Studio") : L("LM Studio hors ligne"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(L("Ce Mac"))
                    .font(.caption)
                Spacer()
                settingsMenu
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
