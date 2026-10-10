import SwiftUI
import AppKit

/// Logos des fournisseurs : PNG de `Resources/Providers`, copiés dans le bundle par `build-app.sh`.
/// `<id>.png` garde ses couleurs ; `<id>.mono.png` est monochrome et prend la couleur du texte (clair/sombre).
/// nil si le fichier manque (tests, `swift run`) : l'appelant garde alors son symbole.
enum ProviderLogo {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ id: String) -> NSImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        for (suffix, template) in [("", false), (".mono", true)] {
            guard let url = Bundle.main.url(forResource: id + suffix, withExtension: "png", subdirectory: "Providers"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = template
            cache.setObject(image, forKey: id as NSString)
            return image
        }
        return nil
    }

    /// Fournisseur d'un modèle de la bibliothèque ; nil pour les moteurs locaux et Ollama.
    static func id(for model: LLMModel) -> String? {
        switch model.source {
        case .alibaba: return "alibaba"
        case .openRouter: return "openrouter"
        case .provider: return CloudProviders.route(model: model.id)?.provider.id
        default: return nil
        }
    }
}

struct ProviderLogoView: View {
    let id: String
    var size: CGFloat = 18

    var body: some View {
        if let image = ProviderLogo.image(id) {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable().scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
