import Foundation

/// Normalisation d'identifiants de modèles — LE cœur de la détection de double-chargement.
///
/// Un même modèle porte des noms différents selon le moteur :
///   Ollama     : `qwen3.8:27b`
///   LM Studio  : `qwen3.8-27b-splash`  ou  `qwen/qwen3.8-27b`
///   MLX direct : `/…/mlx-community/Qwen3.8-27B-4bit` (chemin)
///
/// La normalisation élimine tout ce qui fait varier le nom d'un MÊME modèle :
///   - préfixe éditeur (`qwen/…`, `incoai/…`)
///   - tags Ollama (`:27b` ; `:latest`/`:cloud` sont des alias, retirés)
///   - suffixes de format / quantification / variante
///     (`-mlx`, `-gguf`, `-4bit`, `-q8_0`, `-splash`, `-instruct`, …)
///   - ponctuation (points et tirets supprimés : `llama3.2` ≡ `llama-3.2`)
///
/// Résultat : les trois noms ci-dessus → `qwen3827b` → un seul et même modèle.
///
/// Politique volontairement « zéro faux positif » : on ne déclare un conflit
/// que si deux instances tombent sur la même clé. Une clé peut être un peu
/// grossière (rare), mais deux modèles *différents* qui deviendraient identiques
/// après suppression de suffixes de variante sont quasi inexistants.
enum ModelName {

    /// Suffixes qui désignent un *format*, une *quantification* ou une *variante*
    /// du même modèle (pas un autre modèle). Retirés avant la comparaison.
    private static let variantSuffixes: [String] = [
        // Formats
        "-mlx", "-gguf", "-safetensors", "-yuzu", "-splash", "-amphibian",
        // Quantifications
        "-fp8", "-mxfp8", "-bf16", "-f16", "-f32",
        "-4bit", "-8bit", "-16bit", "-32bit",
        "-b8", "-b16", "-b32",
        "-q2_k", "-q3_k_s", "-q3_k_m", "-q4_0", "-q4_1",
        "-q4_k_s", "-q4_k_m", "-q5_0", "-q5_1", "-q5_k_m", "-q6_k", "-q8_0",
        // Variantes d'entraînement
        "-instruct", "-chat", "-it",
        // Aliases de tag
        "-latest", "-cloud"
    ]

    /// Clé de comparaison normalisée (minuscule, alphanumérique uniquement).
    /// Ex. `qwen3.8:27b` / `qwen3.8-27b-splash` / `qwen/qwen3.8-27b` → `qwen3827b`
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()

        // Préfixe éditeur/publisher : "qwen/qwen3.8-27b" → "qwen3.8-27b"
        if let slash = s.firstIndex(of: "/") {
            s = String(s[s.index(after: slash)...])
        }
        // Un chemin complet ("…/Qwen3.8-27B-4bit") → dernier composant
        if s.contains("/") {
            s = (s as NSString).lastPathComponent
        }

        // Tag Ollama : ":" → "-", sauf les tags alias
        if let colon = s.firstIndex(of: ":") {
            let tag = String(s[s.index(after: colon)...])
            if tag.isEmpty || tag == "latest" || tag == "cloud" {
                s = String(s[..<colon])
            } else {
                s = s.replacingOccurrences(of: ":", with: "-")
            }
        }

        // Retrait itératif des suffixes de variante (ils s'empilent : -instruct-mlx)
        var changed = true
        while changed {
            changed = false
            for suffix in variantSuffixes where s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                changed = true
                break
            }
        }

        // Ponctuation : on ne garde que les caractères alphanumériques.
        // ("llama-3.2" et "llama3.2" → "llama32")
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Deux identifiants désignent-ils le même modèle ?
    static func sameModel(_ a: String, _ b: String) -> Bool {
        let ka = normalize(a), kb = normalize(b)
        return !ka.isEmpty && ka == kb
    }
}
