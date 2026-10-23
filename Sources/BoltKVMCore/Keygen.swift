import Foundation
import CryptoKit
import Security

/// Pre-shared key helpers.
///
/// There is no pairing handshake on the wire: both ends simply hold the same
/// bytes (see `resolveAuthKey` for the lookup order). `keygen` is the missing
/// first step — it makes a key and prints a short fingerprint so two machines
/// can be matched by eye instead of comparing 64 hex characters.
enum PSK {
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
}

extension CLI {
    /// `boltkvm keygen [--path <file>] [--force]`
    public static func runKeygen(_ args: [String]) {
        let path = argValue(args, "--path", "") .isEmpty
            ? (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.boltkvm-key"
            : argValue(args, "--path", "")
        let force = args.contains("--force")
        if FileManager.default.fileExists(atPath: path) && !force {
            log("\(path) already exists; pass --force to replace it")
            exit(1)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            log("keygen: SecRandomCopyBytes failed")
            exit(1)
        }
        let key = Data(bytes)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        do {
            try (hex + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            log("keygen: cannot write \(path): \(error.localizedDescription)")
            exit(1)
        }
        print("wrote \(path) (0600)")
        print("fingerprint \(PSK.fingerprint(key))")
        print("""
        copy this file to the other machine, or paste the same value as the key \
        in the connection editor; both sides must show the same fingerprint
        """)
    }
}
