import Foundation

/// Uses macOS language preferences, including per-app overrides, through Foundation.
enum L10n {
    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    private static let bundle: Bundle = {
        // Resolve explicitly so command-line SwiftPM builds also follow the Mac's
        // languages when the executable has no localized main app bundle.
        let language = Bundle.preferredLocalizations(
            from: ["en", "ko"], forPreferences: Locale.preferredLanguages
        ).first ?? "en"
        guard let path = resourceBundle.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path) else { return resourceBundle }
        return localized
    }()

    private static let resourceBundle: Bundle = {
        // SwiftPM's generated accessor is for command-line layouts. Installed apps
        // keep the resource bundle inside Contents/Resources instead.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("DuoIcon_DuoIcon.bundle"),
           let packaged = Bundle(url: url) {
            return packaged
        }
        return Bundle.module
    }()
}
