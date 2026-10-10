import Foundation

/// La normalisation est LE mécanisme de détection de double-chargement :
/// les mêmes modèles portent des noms différents selon le moteur.
final class ModelNameTests: XCTestCase {

    func testSameModelAcrossEngines() {
        let key = ModelName.normalize("qwen3.8:27b")
        XCTAssertEqual(ModelName.normalize("qwen3.8-27b-splash"), key)   // LM Studio (splash)
        XCTAssertEqual(ModelName.normalize("qwen/qwen3.8-27b"), key)     // LM Studio (mlx, éditeur)
        XCTAssertEqual(ModelName.normalize("Qwen3.8-27B-4bit"), key)     // MLX direct (chemin/dossier)
    }

    func testGemmaVariantsAreIdentical() {
        XCTAssertTrue(ModelName.sameModel("gemma4:e4b-mlx", "gemma-4-e4b-it-mlx"))
        XCTAssertTrue(ModelName.sameModel("gemma4:e4b", "gemma4:e4b-mlx"))
    }

    func testLlamaDotDashAndInstruct() {
        // `llama3.2:1b` (Ollama) ≡ `llama-3.2-1b-instruct` (LM Studio)
        XCTAssertTrue(ModelName.sameModel("llama-3.2-1b-instruct", "llama3.2:1b"))
    }

    func testDifferentVersionsStayDistinct() {
        // Llama 3.0 8B ≠ Llama 3.1 8B — jamais de faux positif.
        XCTAssertFalse(ModelName.sameModel("llama-3-8b", "llama-31-8b"))
        XCTAssertFalse(ModelName.sameModel("qwen3.5:0.8b", "qwen2.5-0.5b"))
    }

    func testAliasesAndVersions() {
        XCTAssertTrue(ModelName.sameModel("clef:latest", "clef"))
        XCTAssertTrue(ModelName.sameModel("deepseek-v4.1-flash:cloud", "deepseek-v4.1-flash"))
        // v1.5 est une VERSION (conserve), -mlx un format (retiré)
        XCTAssertTrue(ModelName.sameModel("text-embedding-nomic-embed-text-v1.5",
                                          "text-embedding-nomic-embed-text-v1.5-mlx"))
    }

    func testPathNormalization() {
        let fromPath = ModelName.normalize("/Users/hugo/.lmstudio/models/mlx-community/Qwen3.8-27B-4bit")
        XCTAssertEqual(fromPath, ModelName.normalize("qwen3.8:27b"))
    }

    // Enregistrement pour le runner minimal (main.swift).
    override func runAll() {
        testSameModelAcrossEngines()
        testGemmaVariantsAreIdentical()
        testLlamaDotDashAndInstruct()
        testDifferentVersionsStayDistinct()
        testAliasesAndVersions()
        testPathNormalization()
    }
}
