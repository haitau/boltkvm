import Foundation
import CryptoKit
import Security

/// Pre-shared key helpers.
///
/// There is no pairing handshake on the wire: both ends simply hold the same
/// bytes (see `resolveAuthKey` for the lookup order). So the first-run story is:
///
/// 1. the 被控端 generates a password on first start (`ensureKey`) and shows it in
///    the 被控端 panel together with a short fingerprint;
/// 2. the operator types that password into the 主控端's host editor once; it is
///    saved per host (`keys/<host>_<port>`, 0600) and reused afterwards;
/// 3. both ends print the same fingerprint, which is how you confirm they agree.
///
/// The password is 8 characters from a 58-symbol alphabet (~46.8 bits). That is
/// fine for the Thunderbolt-bridge threat model (reaching the port already needs
/// physical access) and it is a *passphrase* to `resolveAuthKey`, so no protocol
/// change was needed. Rotating it means `keygen --force` on the server and
/// re-entering it on each client.
enum PSK {
    /// No lookalikes: 0/O, 1/l/I are absent, so a password read off a screen is
    /// never ambiguous.
    static let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ")

    /// 16 hex chars of SHA-256, grouped for readability: `A1B2 C3D4 E5F6 0789`.
    static func fingerprint(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        let hex = digest.prefix(8).map { String(format: "%02X", $0) }.joined()
        var out = ""
        for (index, ch) in hex.enumerated() {
            if index > 0 && index % 4 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// `K7M3-P9QX`: 8 symbols, grouped in two halves so it is easy to read out.
    static func makePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // No practical failure mode on macOS; the fallback keeps a fresh
            // install usable instead of dead.
            bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        let half = chars.count / 2
        return String(chars[..<half]) + "-" + String(chars[half...])
    }

    static var defaultPath: String {
        (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.boltkvm-key"
    }

    /// First line of the key file, if any: the password the operator has to type.
    static func storedText() -> String? {
        guard let text = try? String(contentsOfFile: defaultPath, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }

    /// True when the string looks like a password this generator could produce.
    static func isGeneratedPassword(_ raw: String) -> Bool {
        let compact = raw.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        return compact.count == 8 && compact.allSatisfy { alphabet.contains($0) }
    }

    /// Writes a fresh password to `path` (0600) and returns it. Used by the panel's
    /// "重新生成密码" button: rotating the key is exactly a new file plus a restart.
    static func writeNewPassword(to path: String = defaultPath) throws -> String {
        let password = makePassword()
        try (password + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return password
    }

    /// Creates `~/.boltkvm-key` when neither `--key`, `$BOLTKVM_KEY` nor the file
    /// provide one. Returns the password it wrote, or nil if a key already exists
    /// or writing failed. Never called with `--insecure`: that mode stays explicit.
    @discardableResult
    static func ensureKey(args: [String]) -> String? {
        if resolveAuthKey(args) != nil { return nil }
        let password = makePassword()
        let path = defaultPath
        do {
            try (password + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            log("key: cannot write \(path): \(error.localizedDescription)")
            return nil
        }
        return password
    }
}

extension CLI {
    /// `boltkvm keygen [--path <file>] [--force]`
    public static func runKeygen(_ args: [String]) {
        let custom = argValue(args, "--path", "")
        let path = custom.isEmpty ? PSK.defaultPath : custom
        let force = args.contains("--force")
        if FileManager.default.fileExists(atPath: path) && !force {
            log("\(path) already exists; pass --force to replace it (every client will have to re-enter the password)")
            exit(1)
        }
        let password = PSK.makePassword()
        do {
            try (password + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            log("keygen: cannot write \(path): \(error.localizedDescription)")
            exit(1)
        }
        let key = Data(password.utf8)
        print("wrote \(path) (0600)")
        print("connection password \(password)")
        print("fingerprint \(PSK.fingerprint(key))")
        print("""
        type the password once in the 主控端's host editor; both ends must show the \
        same fingerprint
        """)
    }
}
