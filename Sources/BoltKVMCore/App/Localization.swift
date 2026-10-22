import Foundation

/// UI strings live in `Localizable.strings` (en + zh-Hans) inside the app bundle;
/// macOS picks the table by the user's preferred languages, so a Chinese system
/// gets Chinese and everything else falls back to English. The CLI never calls
/// this — its log lines are developer-facing.
enum L {
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}
