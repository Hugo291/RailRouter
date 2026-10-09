import Foundation

/// Add ("Catalog", CatalogTests.self) to TestRunner.swift to include this suite.
/// Can also compile ModelCatalog.swift + XCTCompat.swift + this file with a temporary main.swift.
final class CatalogTests: XCTestCase {
    private func entry(_ name: String, source: CatalogSource = .lmStudio, format: String = "MLX") -> CatalogEntry {
        let page = source == .ollama ? "https://ollama.com/library/" + name : "https://huggingface.co/" + name
        return CatalogEntry(id: name, name: name, summary: "", source: source,
                            downloadID: name, pageURL: URL(string: page)!, format: format, downloads: 0)
    }

    private func option(_ label: String, _ gb: Double) -> CatalogDownloadOption {
        CatalogDownloadOption(id: label, label: label, downloadID: label, sizeBytes: Int64(gb * 1e9))
    }

    private func testVariantRankingAndEngineChoice() {
        let ranked = CatalogDownloadOption.ranked([option("27b-fp16", 54), option("27b-q8_0", 29), option("27b-q4_K_M", 17), option("latest", 17), option("27b", 17)])
        XCTAssertEqual(ranked.map(\.label), ["latest", "27b", "27b-q4_K_M", "27b-q8_0", "27b-fp16"])
        let ollama = entry("qwen3.8", source: .ollama, format: "Ollama")
        let mlx = entry("lmstudio-community/Qwen3.8-27B-MLX-4bit")
        let gguf = entry("unsloth/Qwen3.8-27B-GGUF", format: "GGUF")
        let both = DiscoveryStore.engineChoices(selected: ollama, related: [gguf, mlx])
        XCTAssertEqual(both.map(\.entry.source), [.ollama, .lmStudio])
        XCTAssertEqual(both.first { $0.recommended }?.entry.id, mlx.id)
        XCTAssertEqual(both.filter(\.recommended).count, 1)
        XCTAssertTrue(DiscoveryStore.engineChoices(selected: ollama, related: []).isEmpty)
        XCTAssertTrue(DiscoveryStore.engineChoices(selected: ollama, related: [entry("other/x", source: .ollama, format: "Ollama")]).isEmpty)
    }

    private func testSizes() {
        let html = #"<li><a href="/library/qwen3.8"><h2 title="qwen3.8"><span>qwen3.8</span></h2><p>x</p><span class="rounded-md bg-[#ddf4ff] text-blue-600">27b</span><span class="bg-[#ddf4ff]">0.8b</span><span class="bg-[#ddf4ff]">e4b</span><span class="bg-indigo-50">tools</span><span title="1,000 downloads">1K</span></a></li>"#
        XCTAssertEqual(CatalogParser.ollamaSearch(html).first?.sizes, ["0.8B", "27B", "E4B"])
        XCTAssertEqual(CatalogParser.ollamaSearch(html).first?.capabilities, ["tools"])
        XCTAssertEqual(CatalogParser.nameSize("lmstudio-community/Qwen3.8-27B-MLX-4bit"), "27B")
        XCTAssertEqual(CatalogParser.nameSize("ornith-ai/Ornith-1.5-35B-A3B-GGUF"), "35B")
        XCTAssertTrue(CatalogParser.nameSize("prism-ml/Ternary-Bonsai-2-27b-gguf") == "27B")
        XCTAssertTrue(CatalogParser.nameSize("org/Model-GGUF") == nil)
        XCTAssertEqual(CatalogParser.ollamaSearch(html).first?.displayCapabilities, ["text", "tools"])
        XCTAssertEqual(entry("org/x").displayCapabilities, ["text"])
        XCTAssertEqual(CatalogParser.ollamaUpdated(#"<span title="Oct 4, 2026 8:59 PM UTC">3 days ago</span>"#)?.timeIntervalSince1970, 1791147540)
        XCTAssertEqual(CatalogParser.isoDate("2026-04-03T15:53:28.000Z")?.timeIntervalSince1970, 1775231608)
        XCTAssertTrue(CatalogParser.isoDate("n'importe quoi") == nil)
    }

    override func runAll() {
        testSizes()
        testVariantRankingAndEngineChoice()
        XCTAssertEqual(CatalogSource.allCases.map(\.id), ["all", "ollama", "lmStudio"])
        XCTAssertEqual(CatalogSource.lmStudio.title, "LM Studio")
        XCTAssertEqual(entry("mlx-community/Qwen3-8B-4bit").familyKey, entry("qwen3", source: .ollama).familyKey)
        XCTAssertEqual(entry("org/Qwen3-8B-GGUF", format: "GGUF").familyKey, "qwen3")
        XCTAssertEqual(entry("org/Qwen3-Coder-30B-A3B-Instruct-GGUF").familyKey, "qwen3-coder")
        XCTAssertEqual(entry("mlx-community/Qwen3.5-0.8B-4bit").familyKey, entry("qwen3.5", source: .ollama).familyKey)
        XCTAssertEqual(entry("org/gemma-4-E4B-it-4bit").familyKey, entry("gemma4", source: .ollama).familyKey)
        XCTAssertEqual(entry("org/Llama-3.2-1B-Instruct-GGUF").familyKey, entry("llama3.2", source: .ollama).familyKey)
        XCTAssertEqual(entry("org/Qwen3.5-9B-Q4_K_M").familyKey, "qwen3.5")
        XCTAssertEqual(entry("org/Qwen3.5-9B-IQ4_XS").familyKey, "qwen3.5")
        XCTAssertFalse(entry("org/Qwen3.5-Distilled-9B-4bit").familyKey == entry("qwen3.5", source: .ollama).familyKey)
        XCTAssertFalse(entry("org/Qwen3.5-27B-splash-4bit").familyKey == entry("qwen3.5", source: .ollama).familyKey)
        XCTAssertFalse(entry("org/Qwen3-Coder-8B-MLX-4bit").familyKey == entry("org/Qwen3-8B-MLX-4bit").familyKey)
        XCTAssertFalse(entry("org/Qwen2.5-8B-MLX").familyKey == entry("org/Qwen3-8B-MLX").familyKey)
        XCTAssertEqual(CatalogParser.clean("<p>A &amp; B &#x1F680; &#39;x&#39;&nbsp; &lt; &amp;lt;</p>"), "A & B 🚀 'x' < &lt;")
        XCTAssertEqual(CatalogParser.clean("&#99999999; &unknown;"), "&#99999999; &unknown;")

        let search = """
        <li><a href="/library/qwen3"><h2><span>qwen3</span></h2>
        <p class="mt-1 max-w-2xl">A &amp; B</p><span title="1,234 downloads">1.2K</span></a></li>
        <li><a href="/library/qwen3"><h2>Duplicate</h2></a></li>
        <li><a href="/alice/custom"><h2><span>alice/custom</span></h2><p>Custom</p>
        <span>2.5M</span><span>&nbsp;Pulls</span></a></li>
        <li><a href="/blog"><h2>Blog</h2></a></li>
        <li><a href="/library/../bad"><h2>Bad</h2></a></li>
        """
        let models = CatalogParser.ollamaSearch(search)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first?.summary, "A & B")
        XCTAssertEqual(models.first?.downloads, 1234)
        XCTAssertEqual(models.last?.downloadID, "alice/custom")
        XCTAssertEqual(models.last?.downloads, 2_500_000)
        XCTAssertTrue(models.allSatisfy { $0.source == .ollama })

        let tags = """
        <a href="/library/qwen3:8b" class="md:hidden"><span>qwen3:8b</span>abc012345678 • 5.2GB</a>
        <a href="/library/qwen3:8b">Duplicate • 5.2GB</a>
        <a href='/library/qwen3:4b-q4_K_M'>2.5GB</a>
        <a href="/library/qwen3:cloud">Cloud</a>
        <a href="/library/qwen3:8b-cloud">Cloud • 5GB</a>
        <a href="/library/other:8b">5GB</a>
        <a href="/library/qwen3:bogus/path">5GB</a>
        """
        let options = CatalogParser.ollamaOptions(tags, model: "qwen3")
        XCTAssertEqual(options.map(\.downloadID), ["qwen3:8b", "qwen3:4b-q4_K_M"])
        XCTAssertEqual(options.first?.sizeBytes, 5_200_000_000)
        XCTAssertEqual(CatalogParser.ollamaOptions("<a href='/alice/custom:v1'>523MB</a>", model: "alice/custom").first?.downloadID, "alice/custom:v1")
        XCTAssertTrue(CatalogParser.ollamaOptions("maintenance", model: "qwen3").isEmpty)

        do {
            let hf = try CatalogParser.huggingFaceSearch(data: Data("""
            [{"id":"org/Qwen3-MLX","downloads":42,"pipeline_tag":"text-generation"},
             {"id":"org/private","private":true},{"id":"org/gated","gated":"manual"},
             {"id":"../bad"},{"id":"org/public","gated":false},
             {"id":"org/detection","pipeline_tag":"object-detection"},
             {"id":"org/audio","pipeline_tag":"text-to-speech"}]
            """.utf8), format: "MLX")
            XCTAssertEqual(hf.count, 2)
            XCTAssertEqual(hf.first?.downloads, 42)
            XCTAssertEqual(hf.first?.summary, "text generation")
            XCTAssertEqual(hf.first?.pageURL.absoluteString, "https://huggingface.co/org/Qwen3-MLX")
            XCTAssertTrue(hf.allSatisfy { $0.source == .lmStudio })
            let allowed = try CatalogParser.huggingFaceSearch(data: Data("""
            [{"id":"org/text","pipeline_tag":"text-generation"},
             {"id":"org/vision","pipeline_tag":"image-text-to-text"},
             {"id":"org/features","pipeline_tag":"feature-extraction"},
             {"id":"org/similarity","pipeline_tag":"sentence-similarity"},
             {"id":"org/unknown"},{"id":"org/asr","pipeline_tag":"automatic-speech-recognition"}]
            """.utf8), format: "GGUF")
            XCTAssertEqual(allowed.count, 5)
            let files = try CatalogParser.huggingFaceOptions(data: Data("""
            {"siblings":[{"rfilename":"model-Q4.gguf","size":23,"lfs":{"size":456}},
             {"rfilename":"nested/model Q8.gguf","size":789},
             {"rfilename":"model-Q4.gguf"}, {"rfilename":"model-00001-of-00002.gguf"},
             {"rfilename":"model-00002-of-00002.gguf"},{"rfilename":"model.part1.gguf"},
             {"rfilename":"mmproj-f16.gguf"},{"rfilename":"MTP/mtp-model.gguf"},
             {"rfilename":"imatrix_unsloth.gguf"},
             {"rfilename":"../evil.gguf"},{"rfilename":"weights.safetensors"}]}
            """.utf8), repository: "org/repo")
            XCTAssertEqual(files.count, 2)
            XCTAssertEqual(files.first?.sizeBytes, 456)
            XCTAssertEqual(files.last?.downloadID, "https://huggingface.co/org/repo/resolve/main/nested/model%20Q8.gguf")
            XCTAssertTrue(files.allSatisfy { $0.id == $0.downloadID })
        } catch { XCTAssertTrue(false) }
        do {
            _ = try CatalogParser.huggingFaceOptions(data: Data(#"{"siblings":[{"rfilename":"model-00001-of-00002.gguf"}]}"#.utf8), repository: "org/repo")
            XCTAssertTrue(false)
        } catch { XCTAssertTrue(true) }
        do {
            _ = try CatalogParser.huggingFaceSearch(data: Data("{}".utf8), format: "MLX")
            XCTAssertTrue(false)
        } catch { XCTAssertTrue(true) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogTestProtocol.self]
        let catalog = ModelCatalog(session: URLSession(configuration: configuration))
        let partial = runSync { await catalog.search(query: "") }
        XCTAssertEqual(partial.entries.map(\.source), [.ollama, .lmStudio])
        XCTAssertEqual(partial.issues.count, 1)
        XCTAssertTrue(partial.issues.first?.contains("MLX: HTTP 503") == true)
        let failed = runSync { await catalog.search(query: "failure") }
        XCTAssertTrue(failed.entries.isEmpty)
        XCTAssertEqual(failed.issues.count, 3)
        let bounded = runSync { await catalog.search(query: "bounded") }
        XCTAssertEqual(bounded.entries.count, 60)
        XCTAssertTrue(bounded.issues.isEmpty)
        let mlx = entry("org/Qwen3-MLX")
        let mlxOptions = runSync { try? await catalog.downloadOptions(for: mlx) }
        XCTAssertEqual(mlxOptions?.first?.downloadID, mlx.pageURL.absoluteString)
        let ollama = entry("qwen3", source: .ollama)
        let exactTags = runSync { try? await catalog.ollamaTags(for: ollama) }
        XCTAssertEqual(exactTags, ["qwen3:8b"])
        let gguf = entry("org/repo", format: "GGUF")
        let ggufOptions = runSync { try? await catalog.downloadOptions(for: gguf) }
        XCTAssertEqual(ggufOptions?.first?.downloadID, "https://huggingface.co/org/repo/resolve/main/model.gguf")
        let invalid = entry("org/repo", source: .all)
        XCTAssertNil(runSync { try? await catalog.downloadOptions(for: invalid) })
        let badHTTP = entry("org/error", format: "GGUF")
        XCTAssertNil(runSync { try? await catalog.downloadOptions(for: badHTTP) })
    }
}

private final class CatalogTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.first { $0.name == "q" || $0.name == "search" }?.value ?? ""
        let filter = items.first { $0.name == "filter" }?.value ?? ""
        var status = 200
        let body: String
        if query == "failure" || url.path == "/api/models/org/error" {
            status = 502; body = "Bad gateway"
        } else if url.path.hasSuffix("/tags") {
            body = #"<a href="/library/qwen3:8b">5.2GB</a>"#
        } else if url.path == "/api/models/org/repo" {
            body = #"{"siblings":[{"rfilename":"model.gguf","size":123}]}"#
        } else if url.host == "ollama.com" {
            body = (0..<(query == "bounded" ? 30 : 1)).map {
                "<li><a href='/library/model\($0)'><h2>model\($0)</h2><p>Model</p></a></li>"
            }.joined()
        } else if filter == "mlx" && query != "bounded" {
            status = 503; body = "Unavailable"
        } else {
            body = "[" + (0..<(query == "bounded" ? 30 : 1)).map {
                "{\"id\":\"org/model\($0)-\(filter)\",\"downloads\":100}"
            }.joined(separator: ",") + "]"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
