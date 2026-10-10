import SwiftUI

struct ChatView: View {
    @EnvironmentObject var modelManager: ModelManager

    var body: some View {
        HStack(spacing: 0) {
            sessionsPane
                .frame(width: 230)
            Divider()
            chatPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // ── CONVERSATIONS ──

    private var sessionsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                modelManager.newChat()
            } label: {
                Label(L("Nouveau chat"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            List(modelManager.chatSessions, selection: $modelManager.currentSessionID) { session in
                Text(session.title)
                    .lineLimit(1)
            }
            .listStyle(.inset)

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25))
    }

    // ── CHAT ──

    private var chatPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(L("Modèle"), selection: $modelManager.selectedModelForChat) {
                    Text(L("Choisir un modèle…")).tag(String?.none)
                    ForEach(modelManager.models.filter { $0.source != .mlxDirect }) { model in
                        Text(model.name).tag(String?.some(model.id))
                    }
                }
                .frame(width: 280)

                Picker(L("Moteur"), selection: $modelManager.selectedEngine) {
                    ForEach(LLMModel.ModelSource.allCases, id: \.self) { source in
                        if source != .cloud && source != .openRouter && source != .alibaba && source != .provider && source != .unknown && source != .mlxDirect {
                            Text(source.rawValue).tag(source)
                        }
                    }
                }
                .frame(width: 150)

                Spacer()

                if modelManager.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            messageList

            Divider()

            HStack(spacing: 10) {
                TextField(L("Votre message…"), text: $modelManager.chatDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(modelManager.isBusy || modelManager.chatDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let session = modelManager.currentSession {
                        ForEach(session.messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    } else {
                        Text(L("Démarrer une conversation."))
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .onChange(of: modelManager.currentSession?.messages.count) { _, _ in
                if let last = modelManager.currentSession?.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == "user" ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            if message.role != "user" { Spacer(minLength: 60) }
        }
    }

    private func send() {
        let text = modelManager.chatDraft
        modelManager.chatDraft = ""
        modelManager.send(text)
    }
}
