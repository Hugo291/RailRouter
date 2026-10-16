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

        // stable-diffusion.cpp (qwen-image.sh / route /v1/images/generations) : ni Python, ni mlx, aucun .gguf resté ouvert.
        let sdCommand = "/Users/hugo/.local/share/sd-cpp/bin/sd-cli --diffusion-model /Users/hugo/.lmstudio/models/abenzerps/Qwen-Image-2.1-Uncensored-Quantized/qwen-image-2.1-UC-Q8_0.gguf --vae /Users/hugo/.lmstudio/models/abenzerps/Qwen-Image-2.1-Uncensored-Quantized/vae/qwen_image_2.1_vae_bf16.safetensors --llm /Users/hugo/.lmstudio/models/lmstudio-community/Qwen3-VL-8B-Instruct-GGUF/Qwen3-VL-8B-Instruct-Q8_0.gguf -p a red apple -n  -W 768 -H 768 --steps 20 -o /tmp/qi-test.png"
        XCTAssertEqual(MLXProcessMonitor.stableDiffusionName(from: sdCommand), "qwen-image-2.1-uncensored-quantized")
        XCTAssertEqual(MLXProcessMonitor.stableDiffusionName(from: "sd-cli -m /models/flux/flux1-dev-Q8_0.gguf -p x"), "flux1-dev-Q8_0")
        XCTAssertEqual(MLXProcessMonitor.stableDiffusionName(from: "/opt/bin/sd-server --listen-port 1234"), "sd-server")
        XCTAssertTrue(!MLXProcessMonitor.isEngineBackend(sdCommand))
        XCTAssertTrue(ProcessScanner.scanMLXProcesses(in: [MLXProcessInfo(pid: 61050, commandLine: sdCommand, ramUsage_MB: 16000)]).isEmpty) // invisible pour le scan MLX
        let sdProcesses = [
            MLXProcessInfo(pid: 61050, commandLine: sdCommand, ramUsage_MB: 16000),
            MLXProcessInfo(pid: 61049, commandLine: "bash /Users/hugo/.ai/skills/use-mlx/scripts/qwen-image.sh a red apple /tmp/qi-test.png 768", ramUsage_MB: 3),
            MLXProcessInfo(pid: 61051, commandLine: "/Users/hugo/.local/bin/sd-server --diffusion-model /models/x.gguf", ramUsage_MB: 9000),
            MLXProcessInfo(pid: 61052, commandLine: "/usr/bin/some-app --flag", ramUsage_MB: 50),
            MLXProcessInfo(pid: 61053, commandLine: "/usr/bin/sd-cli-notes", ramUsage_MB: 1)
        ]
        XCTAssertEqual(ProcessScanner.scanStableDiffusionProcesses(in: sdProcesses).map(\.pid), [61050, 61051])
        XCTAssertEqual(ProcessScanner.scanStableDiffusionProcesses(in: sdProcesses, dylibPIDs: [61052]).map(\.pid), [61050, 61051, 61052])
        let sdLsof = ProcessScanner.parseLsof("""
            p61050
            ftxt
            n/Users/hugo/.local/share/sd-cpp/bin/libstable-diffusion.dylib
            f9
            n/Users/hugo/.lmstudio/models/abenzerps/Qwen-Image-2.1-Uncensored-Quantized/vae/qwen_image_2.1_vae_bf16.safetensors
            """, selfPID: 1)
        XCTAssertEqual(sdLsof.sdPIDs, [61050])
        XCTAssertTrue(sdLsof.mlxPIDs.isEmpty)
    }
}
