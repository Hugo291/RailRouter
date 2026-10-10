import Foundation

final class CodexProbeTests: XCTestCase {
    override func runAll() {
        let done = "id:1\nevent:response.created\ndata:{\"response\":{\"error\":null}}\nevent:response.completed\ndata:{\"response\":{\"status\":\"completed\"}}\n"
        XCTAssertEqual(CodexProbe.verdict(status: 200, body: done)?.compatible, true)
        XCTAssertEqual(CodexProbe.verdict(status: 200, body: "event:response.incomplete\ndata:{}")?.compatible, true)

        // Alibaba renvoie l'échec dans le flux, en HTTP 200 ; le `error: null` de `response.created` ne compte pas.
        let failed = "event:response.created\ndata:{\"response\":{\"error\":null}}\nevent:response.failed\ndata:{\"response\":{\"error\":{\"message\":\"boom\"}}}\n"
        XCTAssertEqual(CodexProbe.verdict(status: 200, body: failed)?.compatible, false)
        XCTAssertEqual(CodexProbe.verdict(status: 200, body: failed)?.reason, "boom")

        let invalid = "{\"request_id\":\"x\",\"error\":{\"code\":\"InvalidParameter\",\"message\":\"1 validation error for Event\"}}"
        XCTAssertEqual(CodexProbe.verdict(status: 500, body: invalid)?.compatible, false)
        XCTAssertEqual(CodexProbe.verdict(status: 500, body: invalid)?.reason, "1 validation error for Event")
        XCTAssertEqual(CodexProbe.verdict(status: 400, body: "")?.reason, "HTTP 400")

        // Clé refusée, quota, réseau, flux vide : on ne conclut pas.
        XCTAssertNil(CodexProbe.verdict(status: 401, body: invalid))
        XCTAssertNil(CodexProbe.verdict(status: 429, body: invalid))
        XCTAssertNil(CodexProbe.verdict(status: 200, body: ""))
    }
}
