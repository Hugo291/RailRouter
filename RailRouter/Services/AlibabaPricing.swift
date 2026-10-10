import Foundation

/// Tarif à la demande d'un modèle Alibaba, en dollars par million de tokens.
struct TokenPrice: Codable, Hashable {
    var input: Double
    var output: Double?
    /// Le tableau tarifie un mode « Thinking » : le modèle sait raisonner.
    var thinking = false

    /// Prix moyen pondéré 3 tokens d'entrée pour 1 de sortie (usage courant d'un assistant).
    var blended: Double { (3 * input + (output ?? input)) / 4 }
    /// $ : < 1 $/M · $$ : < 4 $/M · $$$ : au-delà.
    var tier: Int { blended < 1 ? 1 : blended < 4 ? 2 : 3 }

    /// « in 1.4$/out 4.4$ » (par million de tokens), pour la colonne Prix.
    static func compact(_ price: TokenPrice) -> String {
        func usd(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US"))) + "$" }
        guard let output = price.output else { return "in " + usd(price.input) }
        return "in \(usd(price.input))/out \(usd(output))"
    }

    /// « 1,40 $ entrée · 4,40 $ sortie / M tokens »
    static func summary(_ price: TokenPrice) -> String {
        func usd(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(2...3))) }
        guard let output = price.output else { return L("%@ / M tokens", usd(price.input)) }
        return L("%@ entrée · %@ sortie / M tokens", usd(price.input), usd(output))
    }
}

/// Page officielle « Model pricing » d'Alibaba Cloud Model Studio : tableaux HTML par région.
/// On garde la région Singapour (celle de l'espace de travail, `ap-southeast-1`), portée « International »,
/// premier palier de contexte, prix catalogue (hors remises temporaires). Modèles facturés autrement qu'au token : ignorés.
enum AlibabaPricing {
    static let pageURL = URL(string: "https://www.alibabacloud.com/help/en/model-studio/model-pricing")!
    private static let maxAge: TimeInterval = 24 * 3600

    /// Prix d'un identifiant Alibaba (`kimi/kimi-k3` retombe sur `kimi-k3`).
    static func price(for id: String, in prices: [String: TokenPrice]) -> TokenPrice? {
        prices[id.lowercased()] ?? prices[HuggingFaceFacts.key(id)]
    }

    static func parse(_ html: String) -> [String: TokenPrice] {
        let tags = try! NSRegularExpression(pattern: #"<(/?)(h[1-5]|table|tr|td|th)\b([^>]*)>"#, options: .caseInsensitive)
        let page = html as NSString
        var result: [String: TokenPrice] = [:]
        var heading = "", tableHeading = "", headingStart: Int?, cellStart: Int?, cellSpan = 1, depth = 0
        var rows: [[(text: String, span: Int)]] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: page.length)) {
            let closing = match.range(at: 1).length > 0
            let tag = page.substring(with: match.range(at: 2)).lowercased()
            switch tag {
            case "table":
                if closing {
                    if depth == 1 { collect(rows, heading: tableHeading, into: &result) }
                    depth = max(0, depth - 1)
                } else {
                    depth += 1
                    if depth == 1 { rows = []; tableHeading = heading }
                }
            case "tr":
                if !closing, depth == 1 { rows.append([]) }
            case "td", "th":
                guard depth == 1 else { break }
                if !closing {
                    cellStart = match.range.upperBound
                    let attributes = page.substring(with: match.range(at: 3))
                    cellSpan = attributes.range(of: #"(?<=colspan=")[0-9]+"#, options: .regularExpression).flatMap { Int(attributes[$0]) } ?? 1
                } else if let start = cellStart, !rows.isEmpty {
                    rows[rows.count - 1].append((text(page.substring(with: NSRange(location: start, length: match.range.location - start))), cellSpan))
                    cellStart = nil
                }
            default: // h1…h5 : titre de région au-dessus des tableaux
                if !closing { headingStart = match.range.upperBound }
                else if let start = headingStart {
                    heading = text(page.substring(with: NSRange(location: start, length: match.range.location - start)))
                    headingStart = nil
                }
            }
        }
        return result
    }

    private static func collect(_ rows: [[(text: String, span: Int)]], heading: String, into result: inout [String: TokenPrice]) {
        guard heading.contains("Singapore"), let first = rows.first else { return }
        func expand(_ row: [(text: String, span: Int)]) -> [String] { row.flatMap { Array(repeating: $0.text, count: max(1, $0.span)) } }
        let header = expand(first)
        func column(_ word: String) -> Int? { header.firstIndex { $0.lowercased().contains(word) } }
        guard let input = column("input price"), header[input].lowercased().contains("million tokens") else { return }
        let output = column("output price"), scope = column("deployment scope")
        // Sous-en-tête (« Non-Thinking mode | Thinking mode ») : 2e ligne qui n'a pas toutes les colonnes.
        let subheader = rows.count > 1 && expand(rows[1]).count != header.count ? expand(rows[1]) : []
        let headerThinking = (header + subheader).contains { isThinking($0) }
        for row in rows.dropFirst() {
            // Première ligne d'un modèle uniquement : les paliers suivants n'ont pas toutes leurs cellules.
            let cells = expand(row)
            guard cells.count == header.count, let id = cells[0].split(separator: " ").first.map({ $0.lowercased() }),
                  result[id] == nil, scope.map({ cells[$0] == "International" }) ?? true,
                  let inputPrice = dollars(cells[input]) else { continue }
            result[id] = TokenPrice(input: inputPrice, output: output.flatMap { dollars(cells[$0]) },
                                    thinking: headerThinking || cells.contains { isThinking($0) })
        }
    }

    /// « Thinking » sans le « Non-Thinking » des modèles qui n'ont pas ce mode.
    private static func isThinking(_ text: String) -> Bool {
        text.range(of: #"(?<!non-)thinking"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Premier montant « $1.2 » de la cellule : prix catalogue (ou heures pleines) avant toute remise.
    private static func dollars(_ text: String) -> Double? {
        text.range(of: #"(?<=\$)[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression).flatMap { Double(text[$0]) }
    }

    private static func text(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Page téléchargée au plus une fois par 24 h ; échec réseau → dernier cache, même ancien.
    static func load(session: URLSession = .shared, cache: URL = defaultCache) async -> [String: TokenPrice] {
        let cached = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String: TokenPrice].self, from: $0) }
        if let cached, let date = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < maxAge { return cached }
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return cached ?? [:] }
        let prices = parse(html)
        // Une page vide ou remaniée ne doit pas effacer un bon cache.
        guard prices.count > 50 else { return cached ?? prices }
        if let encoded = try? JSONEncoder().encode(prices) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoded.write(to: cache)
        }
        return prices
    }

    static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RailRouter/alibaba-prices.json")
    }
}
