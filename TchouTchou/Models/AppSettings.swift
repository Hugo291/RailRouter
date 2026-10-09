import Foundation

struct AppSettings {
    // Ollama
    static let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!
    
    // LM Studio
    static let lmStudioBaseURL = URL(string: "http://127.0.0.1:1234")!
    
    // Refresh interval (seconds)
    static let monitorInterval: TimeInterval = 2.0
    
    // Max models to display
    static let maxModels = 50
}
