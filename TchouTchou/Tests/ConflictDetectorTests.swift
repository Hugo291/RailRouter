import Foundation

/// Le détecteur de conflits — cœur métier de l'app.
final class ConflictDetectorTests: XCTestCase {

    private func instance(_ name: String, _ engine: LLMModel.ModelSource, ram: Double = 100) -> ModelInstance {
        ModelInstance(modelName: name, engine: engine, ram_MB: ram, pid: nil, loadedAt: Date(), status: .active)
    }

    func testCrossEngineDoubleLoadIsCritical() {
        let warnings = runSync {
            await ConflictDetector().detectConflicts(instances: [
                self.instance("qwen3.8:27b", .ollama, ram: 16_500),
                self.instance("qwen3.8-27b-splash", .lmStudio, ram: 16_586)
            ])
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.severity, .critical)
        XCTAssertTrue(warnings.first?.engines.contains("Ollama") == true)
        XCTAssertTrue(warnings.first?.engines.contains("LM Studio") == true)
        // Le message mentionne la RAM cumulée.
        XCTAssertTrue(warnings.first?.message.contains("2") == true)
    }

    func testCrossEngineMLXVsLMStudioIsCritical() {
        let warnings = runSync {
            await ConflictDetector().detectConflicts(instances: [
                self.instance("llama-3.2-1b-instruct", .lmStudio),
                self.instance("llama-3.2-1b-instruct-4bit", .mlxDirect)   // même modèle, chemins MLX
            ])
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.severity, .critical)
    }

    func testSameEngineDuplicatesAreWarningNotCritical() {
        let warnings = runSync {
            await ConflictDetector().detectConflicts(instances: [
                self.instance("gemma4:e4b-mlx", .ollama),
                self.instance("gemma4:e4b-mlx", .ollama)
            ])
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.severity, .warning)
    }

    func testDifferentModelsNeverConflict() {
        // État réel du 8 oct. : aucun double chargement.
        let warnings = runSync {
            await ConflictDetector().detectConflicts(instances: [
                self.instance("qwen3.5:0.8b", .ollama, ram: 378),
                self.instance("gemma4:e4b-mlx", .ollama, ram: 8_935),
                self.instance("qwen3.8-27b-splash", .lmStudio, ram: 16_586)
            ])
        }
        XCTAssertTrue(warnings.isEmpty)
    }

    func testSingleInstanceNoConflict() {
        let warnings = runSync {
            await ConflictDetector().detectConflicts(
                instances: [self.instance("qwen3.8:27b", .ollama)])
        }
        XCTAssertTrue(warnings.isEmpty)
    }

    func testCriticalSortedFirst() {
        let warnings = runSync {
            await ConflictDetector().detectConflicts(instances: [
                self.instance("alpha-model", .ollama),
                self.instance("alpha-model", .ollama),            // warning
                self.instance("beta:9b", .ollama, ram: 5000),
                self.instance("beta-9b-splash", .lmStudio, ram: 5000)  // critical
            ])
        }
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(warnings.first?.severity, .critical)
    }

    // Enregistrement pour le runner minimal (main.swift).
    override func runAll() {
        testCrossEngineDoubleLoadIsCritical()
        testCrossEngineMLXVsLMStudioIsCritical()
        testSameEngineDuplicatesAreWarningNotCritical()
        testDifferentModelsNeverConflict()
        testSingleInstanceNoConflict()
        testCriticalSortedFirst()
    }
}
