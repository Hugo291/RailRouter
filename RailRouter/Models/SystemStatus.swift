import Foundation

/// État global du système LLM
struct SystemStatus {
    let ollamaConnected: Bool
    let ollamaVersion: String?
    let lmStudioConnected: Bool
    let lmStudioVersion: String?
    
    let activeInstances: [ModelInstance]
    let totalRAM_MB: Double
    let conflicts: [ConflictWarning]
    let timestamp: Date
    
    var hasConflicts: Bool { !conflicts.isEmpty }
    
    struct ConflictWarning: Identifiable {
        let id = UUID()
        let modelName: String
        let engines: [String]
        let message: String
        let severity: Severity
        
        enum Severity {
            case warning
            case critical
        }
    }
}
