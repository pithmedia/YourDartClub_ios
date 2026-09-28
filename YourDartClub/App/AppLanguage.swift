import SwiftUI

// Both SwiftUI labels and formatted/dynamic strings use the same saved choice.
enum AppLanguage {
    static let preference = "appLanguage"
    static let supported = ["nl", "en", "fr", "de"]
    static var code: String {
        let selected = UserDefaults.standard.string(forKey:preference) ?? ""
        if supported.contains(selected) { return selected }
        return Locale.preferredLanguages.compactMap { language in
            supported.first { language == $0 || language.hasPrefix($0 + "-") }
        }.first ?? "nl"
    }
    static var locale: Locale { Locale(identifier:code) }
    static func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource:code,ofType:"lproj"), let bundle = Bundle(path:path) else { return key }
        return bundle.localizedString(forKey:key,value:nil,table:nil)
    }
}
struct LanguagePicker: View {
    @AppStorage(AppLanguage.preference) private var language = ""
    var body: some View {
        Picker(selection:$language) {
            Text("language_system").tag("")
            Text(verbatim:"Nederlands").tag("nl")
            Text(verbatim:"English").tag("en")
            Text(verbatim:"Français").tag("fr")
            Text(verbatim:"Deutsch").tag("de")
        } label: { Label("language",systemImage:"globe") }
    }
}
