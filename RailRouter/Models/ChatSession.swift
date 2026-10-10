import Foundation

/// Une conversation avec un modèle
struct ChatSession: Identifiable {
    let id = UUID()
    var title: String
    var messages: [ChatMessage]

    init(title: String = "Nouvelle conversation") {
        self.title = title
        self.messages = []
    }
}
