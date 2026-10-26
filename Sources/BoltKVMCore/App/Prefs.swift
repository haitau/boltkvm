import Foundation

enum Role: String {
    case server
    case client

    var title: String {
        switch self {
        case .server: return L.t("role.server")
        case .client: return L.t("role.client")
        }
    }
}

/// One bundle, two roles. The choice is persisted so the app comes back in the
/// same role after a reboot; with no stored role it shows the chooser.
enum Prefs {
    private static let d = UserDefaults.standard

    static var role: Role? {
        get { d.string(forKey: "role").flatMap(Role.init(rawValue:)) }
        set { d.set(newValue?.rawValue, forKey: "role") }
    }

    static var host: String {
        get { d.string(forKey: "client.host") ?? "" }
        set { d.set(newValue, forKey: "client.host") }
    }

    static var port: Int {
        get { d.object(forKey: "client.port") as? Int ?? 7474 }
        set { d.set(newValue, forKey: "client.port") }
    }

    static var forwardInput: Bool {
        get { d.object(forKey: "client.input") as? Bool ?? true }
        set { d.set(newValue, forKey: "client.input") }
    }

    static var audio: Bool {
        get { d.object(forKey: "client.audio") as? Bool ?? false }
        set { d.set(newValue, forKey: "client.audio") }
    }

    static var serverPort: Int {
        get { d.object(forKey: "server.port") as? Int ?? 7474 }
        set { d.set(newValue, forKey: "server.port") }
    }

    static var serverDisplaySize: String {
        get { d.string(forKey: "server.displaySize") ?? "3008x1692" }
        set { d.set(newValue, forKey: "server.displaySize") }
    }

    /// "pixel" (default) streams at the virtual display's real pixel size (2x the
    /// logical size), which is the only way text stays crisp when the client
    /// window is as large as the desktop. "standard" caps the stream at 3840 wide
    /// for slow links.
    static var serverQuality: String {
        get { d.string(forKey: "server.quality") ?? "pixel" }
        set { d.set(newValue, forKey: "server.quality") }
    }

    /// Presets offered in both the controlled Mac's resolution menu and the
    /// controller's host editor. The first two are this setup's real targets:
    /// the 32" HKC on the Thunderbolt bridge at the office (3008×1692 logical,
    /// 6016×3384 backing) and the MacBook Pro panel at home (1728×1117 logical,
    /// 3456×2234 backing). The rest are everyday sizes.
    static let displayPresets: [(String, Int, Int)] = [
        ("3008x1692", 3008, 1692),
        ("1728x1117", 1728, 1117),
        ("1920x1080", 1920, 1080),
        ("2560x1440", 2560, 1440),
        ("2880x1620", 2880, 1620),
        ("3840x2160", 3840, 2160),
    ]

    /// User-added sizes, shared by the controlled Mac's menu/settings and the
    /// controller's host editor *on this Mac*. They are not protocol data: a
    /// size added on one machine does not appear on the other.
    static var customDisplaySizes: [(Int, Int)] {
        get {
            var stored = d.stringArray(forKey: "display.customSizes") ?? []
            // The controller kept its own list before both roles shared one
            // catalog; adopt it instead of dropping the user's entries.
            if stored.isEmpty, let legacy = d.stringArray(forKey: "hosts.customResolutions") {
                stored = legacy
                d.set(legacy, forKey: "display.customSizes")
            }
            return stored.compactMap { text in
                guard let size = DisplaySize.parse(text) else { return nil }
                return (size.width, size.height)
            }
        }
        set {
            d.set(newValue.map { "\($0.0)x\($0.1)" }, forKey: "display.customSizes")
        }
    }

    /// Presets first, then user-added sizes, de-duplicated. Both the controlled
    /// Mac's resolution UI and the controller's host editor read this list.
    static func mergedDisplayOptions(presets: [(String, Int, Int)],
                                     custom: [(Int, Int)]) -> [(Int, Int)] {
        var options = presets.map { ($0.1, $0.2) }
        for size in custom where !options.contains(where: { $0.0 == size.0 && $0.1 == size.1 }) {
            options.append(size)
        }
        return options
    }

    static var displayOptions: [(Int, Int)] {
        mergedDisplayOptions(presets: displayPresets, custom: customDisplaySizes)
    }

    /// Adds a custom size to the shared catalog; built-in sizes are ignored.
    static func rememberDisplaySize(_ size: (Int, Int)) {
        guard !displayPresets.contains(where: { $0.1 == size.0 && $0.2 == size.1 }) else { return }
        var custom = customDisplaySizes
        guard !custom.contains(where: { $0.0 == size.0 && $0.1 == size.1 }) else { return }
        custom.append(size)
        customDisplaySizes = custom
    }

    /// "3008x1692" -> "3008×1692": one title format for both sides.
    static func displayTitle(_ label: String) -> String {
        label.replacingOccurrences(of: "x", with: "×")
    }

    static var serverAudio: Bool {
        get { d.object(forKey: "server.audio") as? Bool ?? false }
        set { d.set(newValue, forKey: "server.audio") }
    }

    static var serverCodec: String {
        get { d.string(forKey: "server.codec") ?? "prores" }
        set { d.set(newValue, forKey: "server.codec") }
    }
}

/// Parses the W×H text used by the custom resolution dialogs. Odd logical sizes
/// are allowed: the MacBook Pro panel's looks-like size is 1728×1117, whose
/// HiDPI backing is even (3456×2234). `Server` rounds the 1x stream down to
/// even for VideoToolbox.
enum DisplaySize {
    static func parse(_ text: String) -> (width: Int, height: Int)? {
        let parts = text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .split(separator: "x")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              (640...7680).contains(width), (480...4320).contains(height)
        else { return nil }
        return (width, height)
    }
}
