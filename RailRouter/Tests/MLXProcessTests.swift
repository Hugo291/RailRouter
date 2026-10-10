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

        // Script Python qui importe mlx : seule libmlx.dylib le trahit (aucun .safetensors resté ouvert).
        let lsof = ProcessScanner.parseLsof("""
            p100
            ftxt
            n/Users/hugo/.venvs/clef/lib/python3.12/site-packages/mlx/lib/libmlx.dylib
            p200
            f12
            n/models/foo/model-00001-of-00003.safetensors
            p300
            ftxt
            n/opt/lib/libmlx.dylib
            """, selfPID: 300)
        XCTAssertEqual(lsof.mlxPIDs, [100])
        XCTAssertEqual(lsof.safetensors.map(\.pid), [200])
        XCTAssertEqual(MLXProcessMonitor.modelName(from: "/Users/hugo/.venvs/clef/bin/python bench_decision.py clef"), "bench_decision.py")
        XCTAssertEqual(MLXProcessMonitor.modelName(from: "/usr/bin/python3 -m mlx_lm.server --port 8080"), "mlx_lm.server")
        XCTAssertEqual(MLXProcessMonitor.modelName(from: "python run.py /models/foo/model-00001.safetensors"), "model-00001")
        XCTAssertEqual(MLXProcessMonitor.modelName(from: "python -m mlx_lm.generate --model mlx-community/Foo-4bit"), "Foo-4bit")
        XCTAssertEqual(MLXProcessMonitor.modelName(from: "/usr/bin/python3"), "MLX (inconnu)")
        // Backends des moteurs exclus, mais pas un serveur MLX direct dont le modèle est rangé sous ~/.lmstudio/models.
        let clef = "/Users/hugo/.venvs/clef/bin/python -c import clef_mlx /Users/hugo/.lmstudio/models/mlx-community/clef-4bit serve --model /Users/hugo/.lmstudio/models/mlx-community/clef-4bit --name clef --port 8091"
        XCTAssertTrue(!MLXProcessMonitor.isEngineBackend(clef))
        XCTAssertEqual(MLXProcessMonitor.modelName(from: clef), "clef")
        XCTAssertTrue(MLXProcessMonitor.isEngineBackend("/Users/hugo/.lmstudio/.internal/utils/node -e connectPort"))
        XCTAssertTrue(MLXProcessMonitor.isEngineBackend("/Users/hugo/.lmstudio/bin/lms log stream --source model"))
        XCTAssertTrue(MLXProcessMonitor.isEngineBackend("/Users/hugo/.lmstudio/extensions/frameworks/lmlink-connector/lmlink-connector"))
        XCTAssertTrue(MLXProcessMonitor.isEngineBackend("/Applications/Ollama.app/Contents/Resources/ollama runner --model x"))
        XCTAssertTrue((ProcessScanner.footprintMB(pid: Int(ProcessInfo.processInfo.processIdentifier)) ?? 0) > 0)
    }
}
