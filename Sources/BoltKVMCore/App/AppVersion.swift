import Foundation

/// The bundle's short version and build number, for surfaces where the user
/// needs to answer "which build am I actually running?" without opening the
/// About panel. Keep it short enough for a menu item and a title bar.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        return display(short: info?["CFBundleShortVersionString"] as? String,
                       build: info?["CFBundleVersion"] as? String)
    }

    static func display(short: String?, build: String?) -> String {
        let short = short?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (short?.isEmpty == false ? short! : "dev")
        guard let build, !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }
}
