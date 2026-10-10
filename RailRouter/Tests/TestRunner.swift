import Foundation

/// Runner de tests minimal (cible unique, module = app) : instancie chaque
/// suite, exécute ses tests via runAll(), rapporte les échecs.
/// Lancé via : `RailRouter --run-tests` (voir RailRouterApp.swift)
/// et `make test`.

func runTestSuite() -> Bool {
    Localization.current = .french  // les assertions portent sur les textes français
    var totalChecks = 0
    var totalFailures = 0

    let suites: [(String, XCTestCase.Type)] = [
        ("UnifiedGateway", UnifiedGatewaySuite.self),
        ("GatewayActivity", GatewayActivityTests.self),
        ("MLXProcess", MLXProcessTests.self),
        ("Catalog", CatalogTests.self),
        ("RuntimeTelemetry", RuntimeTelemetryTests.self),
        ("ModelLibrary", ModelLibraryTests.self),
        ("ModelName", ModelNameTests.self),
        ("ConflictDetector", ConflictDetectorTests.self),
        ("LMStudioService", LMStudioServiceTests.self),
        ("OllamaService", OllamaServiceTests.self),
        ("CodexProbe", CodexProbeTests.self),
        ("CloudProviders", CloudProvidersTests.self)
    ]

    for (suiteName, cls) in suites {
        let instance = cls.init()
        currentTest = instance
        instance.runAll()
        currentTest = nil

        totalChecks += instance.checks
        totalFailures += instance.failures.count

        if instance.failures.isEmpty {
            print("✅ \(suiteName) — \(instance.checks) assertions OK")
        } else {
            print("❌ \(suiteName) — \(instance.failures.count) échec(s) sur \(instance.checks) assertions")
            for f in instance.failures {
                print("   ✗ \(f.expression)  [\(f.file):\(f.line)]")
            }
        }
    }

    print("\n── \(totalChecks) assertions · \(totalFailures) échec(s) ──")
    return totalFailures == 0
}
