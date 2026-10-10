import Foundation

/// Langue de l'interface. Les textes sources sont en français ; l'anglais vient de `Resources/en.lproj/Localizable.strings`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, french, english
    var id: String { rawValue }

    /// Titre affiché dans le menu des réglages (noms de langues volontairement non traduits).
    var title: String {
        switch self {
        case .system: return L("Système")
        case .french: return "Français"
        case .english: return "English"
        }
    }

    /// Langue effectivement utilisée (« Système » suit la première langue préférée de macOS).
    var resolved: AppLanguage {
        guard self == .system else { return self }
        return Locale.preferredLanguages.first?.hasPrefix("fr") == true ? .french : .english
    }

    var localeIdentifier: String { resolved == .french ? "fr" : "en" }
}

enum Localization {
    static let defaultsKey = "appLanguage"
    /// Réglage courant ; mis à jour par `ModelManager.language`.
    static var current: AppLanguage = {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }()
    private static let englishBundle: Bundle? = {
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    }()

    static func text(_ key: String) -> String {
        guard current.resolved == .english, let englishBundle else { return key }
        return englishBundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Texte d'interface localisé (clé = texte français). Les arguments suivent `String(format:)` : `%@`, `%lld`, `%.1f`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let text = Localization.text(key)
    return args.isEmpty ? text : String(format: text, locale: Locale(identifier: Localization.current.localeIdentifier), arguments: args)
}
