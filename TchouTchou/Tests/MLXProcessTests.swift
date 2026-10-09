import Foundation

final class MLXProcessTests: XCTestCase {
    override func runAll() {
        let command = "/Users/hugo/.local/share/uv/tools/mlx-vlm/bin/python /Users/hugo/.local/bin/mlx_vlm.server --host 127.0.0.1 --port 8090 --model mlx-community/Qwen3.8-27B-8bit --draft-model mlx-community/Qwen3.8-27B-MTP-8bit"
        let processes = [
            MLXProcessInfo(pid: 987650, commandLine: command, ramUsage_MB: 24000),
            MLXProcessInfo(pid: 987651, commandLine: "bash \"" + command + "\"", ramUsage_MB: 1),
            MLXProcessInfo(pid: 987652, commandLine: "python my_script.py", ramUsage_MB: 1),
            MLXProcessInfo(pid: 987653, commandLine: "python -m mlx_lm.server --model foo --port 8080", ramUsage_MB: 10)
        ]
        XCTAssertEqual(ProcessScanner.scanMLXProcesses(in: processes).map(\.pid), [987650, 987653])
        XCTAssertEqual(MLXProcessMonitor.argument("--model", in: command), "mlx-community/Qwen3.8-27B-8bit")
        XCTAssertEqual(MLXProcessMonitor.argument("--draft-model", in: command), "mlx-community/Qwen3.8-27B-MTP-8bit")
        XCTAssertEqual(MLXProcessMonitor.serverEndpoint(from: command)?.absoluteString, "http://127.0.0.1:8090/v1")
        XCTAssertEqual(MLXProcessMonitor.argument("--model", in: "python -m mlx_lm.server --model='/models/My Model'"), "/models/My Model")
        XCTAssertTrue(MLXProcessMonitor.serverEndpoint(from: command.replacingOccurrences(of: "8090", with: "65536")) == nil)
        XCTAssertTrue(MLXProcessMonitor.argument("--model", in: "python --draft-model draft") == nil)
    }
}
