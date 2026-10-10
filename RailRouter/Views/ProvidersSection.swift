import SwiftUI

/// Fournisseurs cloud : logo, état, lien vers la page de clé et champ pour la coller. Une fois connecté, ses modèles
/// arrivent dans la bibliothèque et sur l'endpoint sous `<fournisseur>/<modèle>`.
struct ProvidersSection: View {
    @ObservedObject var manager: ModelManager

    var body: some View {
        Section {
            ForEach(CloudProviders.all) { provider in
                ProviderRow(provider: provider, modelCount: count(provider)) { manager.refreshModels() }
            }
        } header: {
            Text(L("Fournisseurs cloud"))
        } footer: {
            Text(L("Collez une clé API pour brancher un fournisseur : elle est vérifiée puis enregistrée dans ~/Library/Application Support/RailRouter (lisible par vous seul). Une variable d’environnement du même nom est aussi reconnue."))
        }
    }

    private func count(_ provider: CloudProvider) -> Int {
        manager.models.filter { model in
            switch provider.id {
            case "alibaba": return model.source == .alibaba
            case "openrouter": return model.source == .openRouter
            default: return model.source == .provider && CloudProviders.route(model: model.id)?.provider.id == provider.id
            }
        }.count
    }
}

/// État d'édition d'une ligne (la chaîne d'outils n'a pas les macros SwiftUI : pas de `@State`, comme `CopyFeedback`).
@MainActor
private final class ProviderConnection: ObservableObject {
    let provider: CloudProvider
    @Published var editing = false
    @Published var draft = ""
    @Published var busy = false
    @Published var notice: String?

    init(provider: CloudProvider) { self.provider = provider }

    func toggleEditing() {
        editing.toggle()
        notice = nil
        draft = ""
    }

    func connect(then done: @escaping () -> Void) {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !busy else { return }
        guard !key.contains(where: \.isWhitespace) else { notice = L("Une clé API ne contient pas d’espace."); return }
        busy = true
        notice = nil
        Task {
            let check = await CloudProviders.verify(provider, key: key)
            switch check {
            case .valid, .unverified:
                do {
                    try CloudProviders.save(key: key, for: provider.id)
                    draft = ""
                    editing = false
                    done()
                } catch { notice = error.localizedDescription }
            case .rejected: notice = L("Clé refusée par %@.", provider.name)
            case .unreachable(let reason): notice = L("%@ injoignable (%@) : clé non enregistrée.", provider.name, reason)
            }
            busy = false
        }
    }

    func disconnect(then done: () -> Void) {
        do { try CloudProviders.remove(id: provider.id); done() } catch { notice = error.localizedDescription }
        objectWillChange.send()
    }
}

private struct ProviderRow: View {
    let provider: CloudProvider
    let modelCount: Int
    let onChange: () -> Void
    @StateObject private var connection: ProviderConnection

    init(provider: CloudProvider, modelCount: Int, onChange: @escaping () -> Void) {
        self.provider = provider
        self.modelCount = modelCount
        self.onChange = onChange
        _connection = StateObject(wrappedValue: ProviderConnection(provider: provider))
    }

    private var stored: Bool { CloudProviders.storedKeys()[provider.id] != nil }
    private var connected: Bool {
        provider.id == "openrouter" ? GatewayOpenRouter.apiKey() != nil : CloudProviders.apiKey(for: provider.id) != nil
    }
    private var origin: String {
        stored ? L("clé enregistrée") : ProcessInfo.processInfo.environment[provider.keyVariable] != nil ? provider.keyVariable : "opencode"
    }
    private var subtitle: String { modelCount > 0 ? L("%lld modèles · %@", modelCount, origin) : origin }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                logo
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name).font(.body.weight(.medium))
                        if connected { Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel(L("Connecté")) }
                    }
                    Text(connected ? subtitle : provider.example)
                        .font(connected ? .caption : .caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if connection.busy { ProgressView().controlSize(.small) }
                trailing
            }
            if connection.editing { editor }
            if let notice = connection.notice { Text(notice).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 2)
    }

    private var logo: some View {
        Group {
            if ProviderLogo.image(provider.id) != nil {
                ProviderLogoView(id: provider.id, size: 20)
            } else {
                Image(systemName: "cloud.fill").font(.system(size: 14)).foregroundStyle(.blue)
            }
        }
        .frame(width: 30, height: 30)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var trailing: some View {
        if connected {
            if stored {
                Button(L("Déconnecter")) { connection.disconnect(then: onChange) }.disabled(connection.busy)
            } else {
                Text(L("Clé détectée")).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Link(L("Obtenir une clé"), destination: URL(string: provider.keyPage)!).font(.callout)
            Button(connection.editing ? L("Annuler") : L("Connecter")) { connection.toggleEditing() }
        }
    }

    private var editor: some View {
        HStack(spacing: 8) {
            SecureField(L("Clé API"), text: $connection.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { connection.connect(then: onChange) }
            Button(L("Enregistrer")) { connection.connect(then: onChange) }
                .keyboardShortcut(.defaultAction)
                .disabled(connection.busy || connection.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
