import Foundation

/// Mini-harness « XCTest » — cette machine n'a pas Xcode complet (le framework
/// XCTest n'existe pas dans CommandLineTools). Équivalent minimal :
/// classe de base + assertions + runner (main.swift).
/// Avec un Xcode complet, il suffirait de réécrire `import XCTest` dans les
/// fichiers de tests et de supprimer ce fichier.

class XCTestCase {
    required init() {}

    var checks = 0
    var failures: [(expression: String, file: String, line: Int)] = []

    /// À surcharger : exécute tous les tests de la suite.
    func runAll() {}

    func fail(_ expression: String, _ file: String, _ line: Int) {
        failures.append((expression, file, line))
    }
}

/// Instance du test en cours (exécution sériée par main.swift).
var currentTest: XCTestCase?

// ── Assertions ──

func XCTAssertEqual<T: Equatable>(
    _ e1: T?, _ e2: T?, _ file: String = #fileID, _ line: Int = #line
) {
    currentTest?.checks += 1
    guard e1 == e2 else {
        currentTest?.fail("XCTAssertEqual: \(String(describing: e1)) != \(String(describing: e2))", file, line)
        return
    }
}

func XCTAssertEqual(
    _ e1: Double?, _ e2: Double, accuracy: Double, _ file: String = #fileID, _ line: Int = #line
) {
    currentTest?.checks += 1
    guard let e1, abs(e1 - e2) <= accuracy else {
        currentTest?.fail("XCTAssertEqual(accuracy \(accuracy)): \(String(describing: e1)) vs \(e2)", file, line)
        return
    }
}

func XCTAssertEqual(
    _ e1: Date?, _ e2: Date, accuracy: Double, _ file: String = #fileID, _ line: Int = #line
) {
    currentTest?.checks += 1
    guard let e1, abs(e1.timeIntervalSince(e2)) <= accuracy else {
        currentTest?.fail("XCTAssertEqual(accuracy \(accuracy)): \(String(describing: e1)) vs \(e2)", file, line)
        return
    }
}

func XCTAssertTrue(_ value: Bool, _ file: String = #fileID, _ line: Int = #line) {
    currentTest?.checks += 1
    guard value else { currentTest?.fail("XCTAssertTrue", file, line); return }
}

func XCTAssertFalse(_ value: Bool, _ file: String = #fileID, _ line: Int = #line) {
    currentTest?.checks += 1
    guard !value else { currentTest?.fail("XCTAssertFalse", file, line); return }
}

func XCTAssertNotNil<T>(_ value: T?, _ file: String = #fileID, _ line: Int = #line) {
    currentTest?.checks += 1
    guard value != nil else { currentTest?.fail("XCTAssertNotNil", file, line); return }
}

func XCTAssertNil<T>(_ value: T?, _ file: String = #fileID, _ line: Int = #line) {
    currentTest?.checks += 1
    guard value == nil else { currentTest?.fail("XCTAssertNil", file, line); return }
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ e1: T?, _ e2: T, _ file: String = #fileID, _ line: Int = #line
) {
    currentTest?.checks += 1
    guard let e1, e1 >= e2 else {
        currentTest?.fail("XCTAssertGreaterThanOrEqual: \(String(describing: e1)) < \(e2)", file, line)
        return
    }
}

/// Exécute un bloc async de façon synchrone (tests sériés par le runner).
func runSync<T>(_ body: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    var out: T?
    Task {
        out = await body()
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    return out!
}
