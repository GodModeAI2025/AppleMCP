import Foundation
let app = Bundle(path: CommandLine.arguments[1])!
assert(Set(app.localizations).isSuperset(of: ["de", "en"]))
assert(app.developmentLocalization == "de")
for (preferences, expected) in [(["de-DE", "en-GB"], "de"), (["en-US", "de-DE"], "en"), (["fr-FR", "en-GB"], "en"), (["de-CH"], "de")] {
    let selected = Bundle.preferredLocalizations(from: app.localizations, forPreferences: preferences)
    assert(selected.first == expected, "\(preferences): \(selected)")
    print("\(preferences) → \(selected)")
}
for (language, expected) in [("de", "Kalender"), ("en", "Calendar")] {
    let localized = Bundle(path: app.path(forResource: language, ofType: "lproj")!)!
    assert(localized.localizedString(forKey: "Kalender", value: nil, table: "Localizable") == expected)
    let prompt = localized.localizedString(forKey: "NSCalendarsFullAccessUsageDescription", value: nil, table: "InfoPlist")
    assert(prompt.contains(language == "de" ? "Kalenderdaten" : "calendar data"))
    print("\(language): native label and calendar usage description OK")
}
