import Foundation

enum CatalogSource: String, CaseIterable, Identifiable, Sendable {
    case all, ollama, lmStudio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L("Tous")
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }
}

struct CatalogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let source: CatalogSource
    let downloadID: String
    let pageURL: URL
    let format: String
    let downloads: Int
    /// Tailles disponibles (« 0.8B », « 27B »…), telles que le catalogue les annonce.
    var sizes: [String] = []
    /// Capacités annoncées par le catalogue (« vision », « tools », « thinking »…).
    var capabilities: [String] = []
    /// Toute entrée traite du texte ; les autres capacités sont celles annoncées par le catalogue.
    var displayCapabilities: [String] {
        var seen = Set<String>(["text"])
        return ["text"] + capabilities.filter { seen.insert($0).inserted }
    }
    /// Date de création du dépôt (Hugging Face) ; Ollama ne l'expose pas.
    var released: Date? = nil
    /// Dernière modification annoncée par le catalogue.
    var updated: Date? = nil

    /// A name-based grouping hint, never a claim of identical weights or capabilities.
    /// Preserve specialized modifiers (coder, distilled, splash, etc.) and model versions.
    var familyKey: String {
        var stem = name.split(separator: "/").last.map(String.init) ?? name
        if source == .ollama { stem = stem.components(separatedBy: ":")[0] }
        stem = stem.lowercased().replacingOccurrences(of: "_", with: "-")
        var previous = ""
        while previous != stem {
            previous = stem
            stem = stem.replacingOccurrences(
                of: #"-(?:mlx|gguf|instruct|it|\d+-?bits?|i?q\d+(?:-[kmsxl0-9]+)*|[bf]f?16|[ea]?\d+(?:\.\d+)?b(?:-a\d+(?:\.\d+)?b)?)$"#,
                with: "", options: .regularExpression)
        }
        return stem.replacingOccurrences(
            of: #"^(qwen|llama|gemma|phi|olmo|granite|falcon|smollm)-(?=\d)"#,
            with: "$1", options: .regularExpression)
    }
}

struct CatalogSearchResult: Sendable {
    let entries: [CatalogEntry]
    let issues: [String]
}

struct CatalogDownloadOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let downloadID: String
    let sizeBytes: Int64?
}

extension CatalogDownloadOption {
    /// Les catalogues n'exposent pas de téléchargements par variante : classement par usage courant
    /// (étiquette par défaut puis Q4_K_M, la quantification la plus répandue), puis taille croissante.
    var preferenceScore: Int {
        let name = label.lowercased()
        if name == "latest" || name.hasSuffix(":latest") { return 100 }
        if name.range(of: #"^\d+(?:\.\d+)?[bm]$"#, options: .regularExpression) != nil { return 90 }
        let ranking: [(String, Int)] = [("q4_k_m", 80), ("mxfp4", 72), ("nvfp4", 72), ("q5_k_m", 65), ("q6_k", 55),
                                        ("q8_0", 50), ("mxfp8", 50), ("q4_k_s", 45), ("q4_0", 40),
                                        ("fp16", 10), ("bf16", 10), ("f16", 10), ("f32", 5)]
        return ranking.first { name.contains($0.0) }?.1 ?? 30
    }

    static func ranked(_ options: [CatalogDownloadOption]) -> [CatalogDownloadOption] {
        options.sorted {
            if $0.preferenceScore != $1.preferenceScore { return $0.preferenceScore > $1.preferenceScore }
            if let a = $0.sizeBytes, let b = $1.sizeBytes, a != b { return a < b }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }
}

actor ModelCatalog {
    private let session: URLSession
    static let resultLimit = 60 // Up to 20 results from each independent discovery feed.

    init(session: URLSession = .shared) { self.session = session }

    func search(query: String) async -> CatalogSearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        async let ollama = searchFeed(query: query, format: "Ollama")
        async let mlx = searchFeed(query: query, format: "MLX")
        async let gguf = searchFeed(query: query, format: "GGUF")
        let feeds = await [ollama, mlx, gguf]
        var seen = Set<String>()
        return CatalogSearchResult(
            entries: Array(feeds.flatMap(\.entries).filter { seen.insert($0.id).inserted }.prefix(Self.resultLimit)),
            issues: feeds.flatMap(\.issues))
    }

    func ollamaUpdated(for entry: CatalogEntry) async -> Date? {
        guard entry.source == .ollama, entry.pageURL.host == "ollama.com",
              let data = try? await fetch(entry.pageURL, accept: "text/html"),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return CatalogParser.ollamaUpdated(html)
    }

    func ollamaTags(for entry: CatalogEntry) async throws -> [String] {
        try await ollamaOptions(for: entry).map(\.downloadID)
    }

    func downloadOptions(for entry: CatalogEntry) async throws -> [CatalogDownloadOption] {
        switch entry.source {
        case .ollama: return try await ollamaOptions(for: entry)
        case .lmStudio:
            guard entry.pageURL.scheme == "https", entry.pageURL.host == "huggingface.co",
                  Self.validRepository(entry.downloadID),
                  entry.pageURL.path == "/" + entry.downloadID else { throw CatalogError.invalidEntry }
            if entry.format.uppercased() == "MLX" {
                let url = entry.pageURL.absoluteString
                return [CatalogDownloadOption(id: url, label: entry.name, downloadID: url, sizeBytes: nil)]
            }
            guard entry.format.uppercased() == "GGUF" else { throw CatalogError.invalidEntry }
            let url = Self.url("https://huggingface.co/api/models/" + entry.downloadID,
                               items: [URLQueryItem(name: "blobs", value: "true")])
            return try CatalogParser.huggingFaceOptions(data: await fetch(url, accept: "application/json"), repository: entry.downloadID)
        case .all: throw CatalogError.invalidEntry
        }
    }

    private func ollamaOptions(for entry: CatalogEntry) async throws -> [CatalogDownloadOption] {
        guard entry.source == .ollama, Self.validRepository(entry.pageURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              entry.pageURL.scheme == "https", entry.pageURL.host == "ollama.com",
              entry.pageURL.path == "/library/" + entry.downloadID || entry.pageURL.path == "/" + entry.downloadID
        else { throw CatalogError.invalidEntry }
        let data = try await fetch(entry.pageURL.appendingPathComponent("tags"), accept: "text/html")
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.invalidResponse }
        let options = CatalogParser.ollamaOptions(html, model: entry.downloadID)
        guard !options.isEmpty else { throw CatalogError.noDownloads }
        return options
    }

    private func searchFeed(query: String, format: String) async -> CatalogSearchResult {
        do {
            let entries: [CatalogEntry]
            if format == "Ollama" {
                let url = Self.url("https://ollama.com/search", items: [URLQueryItem(name: "q", value: query)])
                let data = try await fetch(url, accept: "text/html")
                guard let html = String(data: data, encoding: .utf8),
                      html.contains("<li") || html.contains("data-result-count") || html.localizedCaseInsensitiveContains("no models")
                else { throw CatalogError.invalidResponse }
                entries = CatalogParser.ollamaSearch(html)
                if entries.isEmpty && !html.contains("data-result-count=\"0\"") && !html.localizedCaseInsensitiveContains("no models") {
                    throw CatalogError.invalidResponse
                }
            } else {
                let url = Self.url("https://huggingface.co/api/models", items: [
                    URLQueryItem(name: "filter", value: format.lowercased()),
                    URLQueryItem(name: "search", value: query),
                    URLQueryItem(name: "sort", value: "downloads"),
                    URLQueryItem(name: "direction", value: "-1"),
                    URLQueryItem(name: "limit", value: "20")] +
                    ["downloads", "pipeline_tag", "gated", "private", "createdAt", "lastModified"].map { URLQueryItem(name: "expand[]", value: $0) })
                entries = try CatalogParser.huggingFaceSearch(data: await fetch(url, accept: "application/json"), format: format)
            }
            return CatalogSearchResult(entries: Array(entries.prefix(20)), issues: [])
        } catch {
            return CatalogSearchResult(entries: [], issues: ["\(format == "Ollama" ? "Ollama" : "Hugging Face " + format): \(error.localizedDescription)"])
        }
    }

    private func fetch(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CatalogError.http(http.statusCode) }
        guard data.count <= 16 * 1024 * 1024 else { throw CatalogError.invalidResponse }
        return data
    }

    private static func url(_ base: String, items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items
        return components.url!
    }

    static func validRepository(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        }
    }
}

private enum CatalogError: LocalizedError {
    case http(Int), invalidResponse, invalidEntry, noDownloads
    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .invalidResponse: return L("Réponse du catalogue non reconnue.")
        case .invalidEntry: return L("Entrée du catalogue invalide.")
        case .noDownloads: return L("Aucune variante locale téléchargeable.")
        }
    }
}

// HTML parsing adapted from ollama-gui/Sources/OllamaKit/LibraryClient.swift.
// MIT License — Copyright (c) 2026 Hugo Ferreira
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
enum CatalogParser {
    static func ollamaSearch(_ html: String) -> [CatalogEntry] {
        var seen = Set<String>()
        return matches(#"<li\b[^>]*>(.*?)</li>"#, html).compactMap { item in
            let body = item[1]
            guard let path = matches(#"<a\b[^>]*href=["']/([^"'?#]+)["']"#, body).first?[1],
                  ModelCatalog.validRepository(path),
                  let title = matches(#"<h2\b[^>]*>(.*?)</h2>"#, body).first?[1],
                  seen.insert(path).inserted else { return nil }
            let name = clean(title)
            guard !name.isEmpty else { return nil }
            let summary = matches(#"<p\b[^>]*>(.*?)</p>"#, body).first.map { clean($0[1]) } ?? ""
            let count = matches(#"title=["']([\d,]+) downloads?["']"#, body).first?[1]
                ?? matches(#"<span[^>]*>([^<]*)</span>\s*<span[^>]*>\s*(?:&nbsp;)?\s*Pulls?"#, body).first?[1] ?? "0"
            let sizes = matches(#"<span\b[^>]*bg-\[#ddf4ff\][^>]*>(.*?)</span>"#, body).map { clean($0[1]).uppercased() }.filter { !$0.isEmpty }
            let capabilities = matches(#"<span\b[^>]*bg-indigo-50[^>]*>(.*?)</span>"#, body).map { clean($0[1]).lowercased() }.filter { !$0.isEmpty && $0 != "cloud" }
            return CatalogEntry(id: "ollama:" + path, name: name, summary: summary, source: .ollama,
                                downloadID: path.hasPrefix("library/") ? String(path.dropFirst(8)) : path,
                                pageURL: URL(string: "https://ollama.com/" + path)!, format: "Ollama", downloads: downloadCount(count),
                                sizes: sortedSizes(sizes), capabilities: capabilities)
        }
    }

    static func ollamaOptions(_ html: String, model: String) -> [CatalogDownloadOption] {
        var seen = Set<String>()
        return Array(matches(#"<a\b[^>]*href=["']/([^"'?#]+:[^"'?#]+)["'][^>]*>(.*?)</a>"#, html).compactMap { link in
            let name = link[1].hasPrefix("library/") ? String(link[1].dropFirst(8)) : link[1]
            guard name.hasPrefix(model + ":") else { return nil }
            let tag = String(name.dropFirst(model.count + 1))
            guard !tag.isEmpty, tag.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  tag != "cloud", !tag.hasSuffix("-cloud"),
                  let size = matches(#"\b(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB)\b"#, clean(link[2])).first,
                  seen.insert(name).inserted else { return nil }
            let multiplier: Double = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][size[2].uppercased()]!
            let bytes = (Double(size[1]) ?? 0) * multiplier
            return CatalogDownloadOption(id: name, label: name, downloadID: name,
                                         sizeBytes: bytes > 0 && bytes < Double(Int64.max) ? Int64(bytes) : nil)
        }.prefix(2000))
    }

    private struct HFModel: Decodable {
        let id: String
        let downloads: Int?
        let pipeline_tag: String?
        let privateModel: Bool?
        let gated: Gated?
        let createdAt: String?
        let lastModified: String?
        enum CodingKeys: String, CodingKey { case id, downloads, pipeline_tag, gated, createdAt, lastModified; case privateModel = "private" }
        enum Gated: Decodable {
            case flag(Bool), mode(String)
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
                else { self = .mode(try value.decode(String.self)) }
            }
            var restricted: Bool { if case .flag(false) = self { return false }; return true }
        }
    }

    static func huggingFaceSearch(data: Data, format: String) throws -> [CatalogEntry] {
        let supportedTasks: Set<String> = ["text-generation", "image-text-to-text", "feature-extraction", "sentence-similarity"]
        return try JSONDecoder().decode([HFModel].self, from: data).filter {
            ModelCatalog.validRepository($0.id) && $0.privateModel != true && $0.gated?.restricted != true
                && ($0.pipeline_tag == nil || supportedTasks.contains($0.pipeline_tag!))
        }.prefix(20).map {
            CatalogEntry(id: "hf:\(format.lowercased()):\($0.id)", name: $0.id,
                         summary: $0.pipeline_tag?.replacingOccurrences(of: "-", with: " ") ?? "Hugging Face · \(format)",
                         source: .lmStudio, downloadID: $0.id,
                         pageURL: URL(string: "https://huggingface.co/" + $0.id)!, format: format, downloads: max(0, $0.downloads ?? 0),
                         sizes: nameSize($0.id).map { [$0] } ?? [], capabilities: hfCapabilities($0.pipeline_tag),
                         released: isoDate($0.createdAt), updated: isoDate($0.lastModified))
        }
    }

    /// Taille lue dans le nom du dépôt (« Qwen3.8-27B-MLX » → « 27B »), jamais devinée.
    static func nameSize(_ repository: String) -> String? {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        guard let range = name.range(of: #"(?<![A-Za-z0-9.])\d+(?:\.\d+)?[BbMm](?![A-Za-z])"#, options: .regularExpression) else { return nil }
        return name[range].uppercased()
    }

    static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Date exacte de dernière mise à jour d'une fiche Ollama (« Oct 4, 2026 8:59 PM UTC »).
    static func ollamaUpdated(_ html: String) -> Date? {
        guard let stamp = matches(#"title=["']([A-Z][a-z]{2} \d{1,2}, \d{4} \d{1,2}:\d{2} [AP]M UTC)["']"#, html).first?[1] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, yyyy h:mm a 'UTC'"
        return formatter.date(from: stamp)
    }

    private static func hfCapabilities(_ task: String?) -> [String] {
        switch task {
        case "image-text-to-text": return ["vision"]
        case "feature-extraction", "sentence-similarity": return ["embedding"]
        default: return []
        }
    }

    static func sortedSizes(_ sizes: [String]) -> [String] {
        var seen = Set<String>()
        return sizes.filter { seen.insert($0).inserted }.sorted {
            let a = parameterValue($0), b = parameterValue($1)
            return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func parameterValue(_ size: String) -> Double {
        guard let range = size.range(of: #"^\d+(?:\.\d+)?[BM]"#, options: .regularExpression) else { return .infinity }
        let token = size[range]
        let number = Double(token.dropLast()) ?? .infinity
        return token.hasSuffix("M") ? number / 1000 : number
    }

    private struct HFRepository: Decodable {
        let siblings: [File]
        struct File: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let size: Int64? }
        }
    }

    static func huggingFaceOptions(data: Data, repository: String) throws -> [CatalogDownloadOption] {
        guard ModelCatalog.validRepository(repository) else { throw CatalogError.invalidEntry }
        let files = try JSONDecoder().decode(HFRepository.self, from: data).siblings
        var seen = Set<String>()
        let options: [CatalogDownloadOption] = files.compactMap { file in
            let path = file.rfilename
            let lower = path.lowercased()
            guard lower.hasSuffix(".gguf"),
                  lower.range(of: #"(?:-\d+-of-\d+|\.part\d+)\.gguf$"#, options: .regularExpression) == nil,
                  !lower.split(separator: "/").contains(where: {
                      $0.hasPrefix("mmproj") || $0.hasPrefix("mtp") || $0.hasPrefix("imatrix")
                  }),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  seen.insert(path).inserted else { return nil }
            // Encode each component: spaces, #, ?, etc. must never change the selected file.
            let url = path.split(separator: "/").reduce(URL(string: "https://huggingface.co/\(repository)/resolve/main")!) {
                $0.appendingPathComponent(String($1))
            }.absoluteString
            let size = file.lfs?.size ?? file.size
            return CatalogDownloadOption(id: url, label: path, downloadID: url, sizeBytes: size.flatMap { $0 >= 0 ? $0 : nil })
        }
        guard !options.isEmpty else { throw CatalogError.noDownloads }
        return Array(options.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }.prefix(200))
    }

    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { string.substring(with: match.range(at: $0)) }
        }
    }

    static func clean(_ html: String) -> String {
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = NSMutableString(string: plain)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        // Decode exactly once, so escaped markup stays text.
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);"#, options: .caseInsensitive)
        let original = plain as NSString
        for match in regex.matches(in: plain, range: NSRange(location: 0, length: original.length)).reversed() {
            let entity = original.substring(with: match.range(at: 1))
            let number = entity.lowercased().hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil
            let value = entities[entity] ?? number.flatMap(Unicode.Scalar.init).map(String.init)
            if let value { decoded.replaceCharacters(in: match.range, with: value) }
        }
        return (decoded as String).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func downloadCount(_ text: String) -> Int {
        let text = clean(text).replacingOccurrences(of: ",", with: "").uppercased()
        let factor: Double = text.hasSuffix("K") ? 1e3 : text.hasSuffix("M") ? 1e6 : text.hasSuffix("B") ? 1e9 : 1
        let value = (Double(factor == 1 ? text : String(text.dropLast())) ?? 0) * factor
        return value >= 0 && value < Double(Int.max) ? Int(value) : 0
    }
}
