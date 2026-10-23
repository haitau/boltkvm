import Foundation
import CryptoKit
import Security
import CommonCrypto

/// Pre-shared key helpers.
///
/// There is no pairing handshake on the wire: both ends simply hold the same
/// bytes (see `resolveAuthKey` for the lookup order). So the first-run story is:
///
/// 1. the server generates a password on first start (`ensureKey`) and shows it in
///    the server panel together with a short fingerprint;
/// 2. the operator types that password into the client's host editor once; it is
///    saved per host (`keys/<host>_<port>`, 0600) and reused afterwards;
/// 3. both ends print the same fingerprint, which is how you confirm they agree.
///
/// The password is 8 characters from a 31-symbol alphabet (~40 bits). That is
/// fine for the Thunderbolt-bridge threat model (reaching the port already needs
/// physical access) and it is a *passphrase* to `resolveAuthKey`, so no protocol
/// change was needed. Rotating it means `keygen --force` on the server and
/// re-entering it on each client.
enum PSK {
    /// Lowercase + digits, with the lookalikes removed (0/o, 1/l/i): a password
    /// read off a screen or typed on another keyboard has no case to get wrong.
    static let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

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

    /// 8 lowercase characters from the 31-symbol alphabet (e.g. `k7m3p9qx`).
    static func makePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // No practical failure mode on macOS; the fallback keeps a fresh
            // install usable instead of dead.
            bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
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

    /// Whatever the user typed: no separators, no case. `K7M3-P9QX`, `k7m3 p9qx`
    /// and `K7M3P9QX` all become the same password.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    /// True when the string looks like a password this generator could produce.
    static func isGeneratedPassword(_ raw: String) -> Bool {
        let compact = normalize(raw)
        return compact.count == 8 && compact.allSatisfy { alphabet.contains($0) }
    }

    /// A 64-character hex string is a 256-bit static key: used as raw PSK bytes,
    /// not stretched (there is nothing to stretch). Both ends must paste the same
    /// 64 characters.
    static func isStaticKey(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count == 64 && t.allSatisfy { $0.isHexDigit }
    }

    /// 32 random bytes as lowercase hex, the "high-entropy" alternative to the
    /// 8-character password. 256 bits cannot be brute-forced offline at all, at
    /// the cost of being impossible to type by hand.
    static func makeStaticKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Middle-truncated form for the settings panel: 64 characters do not fit
    /// next to the fingerprint, and the copy button carries the full value.
    static func shortKey(_ key: String) -> String {
        guard key.count > 20 else { return key }
        return String(key.prefix(8)) + "…" + String(key.suffix(6))
    }

    /// Replaces the key file with a fresh static key. Same 0600 file the rest of
    /// the code reads, so nothing else has to know which kind it is.
    @discardableResult
    static func writeStaticKey(to path: String = defaultPath) throws -> String {
        let key = makeStaticKey()
        try (key + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return key
    }

    /// The 8-character alphabet is only ~40 bits, which is fine online (one guess
    /// per second) but weak offline if someone captures a handshake. Stretching it
    /// with PBKDF2 makes each offline guess ~100 ms instead of ~1 µs, so an
    /// 8-character password behaves like a much longer one in practice.
    static func stretch(_ password: String) -> Data {
        let salt = Array("boltkvm-psk-v1".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let input = Array(normalize(password).utf8)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          input, input.count,
                                          salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          120_000,
                                          &out, out.count)
        if status != kCCSuccess {
            return Data(SHA256.hash(data: Data(input)))
        }
        return Data(out)
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
        // The handshake uses the stretched key, so the fingerprint shown here has
        // to be the stretched one too: otherwise "both ends must show the same
        // fingerprint" can never hold.
        let key = PSK.stretch(password)
        print("wrote \(path) (0600)")
        print("connection password \(password)")
        print("fingerprint \(PSK.fingerprint(key))")
        print("""
        type the password once in the controller's host editor; both ends must show the \
        same fingerprint
        """)
    }
}
