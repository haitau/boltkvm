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

    /// Presets offered in the server menu; vdscreen-style, plus a custom entry.
    static let displayPresets: [(String, Int, Int)] = [
        ("1920x1080", 1920, 1080),
        ("2560x1440", 2560, 1440),
        ("2880x1620", 2880, 1620),
        ("3008x1692", 3008, 1692),
        ("3840x2160", 3840, 2160),
        ("5120x2880", 5120, 2880),
        ("6016x3384", 6016, 3384),
    ]

    static var serverAudio: Bool {
        get { d.object(forKey: "server.audio") as? Bool ?? false }
        set { d.set(newValue, forKey: "server.audio") }
    }

    static var serverCodec: String {
        get { d.string(forKey: "server.codec") ?? "prores" }
        set { d.set(newValue, forKey: "server.codec") }
    }
}

/// Shared key file helpers. The CLI resolves --key > $BOLTKVM_KEY > ~/.boltkvm-key;
/// the app uses the same file so both transports speak the same secret.
enum AppKey {
    static var path: String { NSHomeDirectory() + "/.boltkvm-key" }

    static var exists: Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Creates a random 32-byte key on first run so the server never comes up
    /// without auth by accident.
    @discardableResult
    static func ensure() -> Bool {
        if exists { return true }
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard (try? hex.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }
}
