import Foundation

/// Per-host pre-shared keys, stored as 0600 files next to `hosts.json`.
///
/// Deliberately not Keychain: every build re-signs the app, and a Keychain item's
/// ACL is tied to the code signature, so each rebuild looks like a different app
/// and macOS pops "BoltKVM 想使用您储存在钥匙串中的…" asking for the login password
/// on connect (measured 2026-10-23 — the connect silently stalled behind that
/// dialog). The single-host key (`~/.boltkvm-key`) already lives in the home
/// directory with the same posture, so a directory of 0600 files is consistent and
/// survives rebuilds.
enum HostSecrets {
    static var directory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BoltKVM/keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return base
    }

    /// Account names come from `host:port`; ":" is legal in a file name but
    /// confusing in Finder, so it becomes "_".
    private static func url(for account: String) -> URL {
        directory.appendingPathComponent(account.replacingOccurrences(of: ":", with: "_"))
    }

    @discardableResult
    static func set(_ secret: String, account: String) -> Bool {
        let path = url(for: account)
        do {
            try Data(secret.utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch {
            log("secret: cannot write key for \(account): \(error.localizedDescription)")
            return false
        }
    }

    static func get(account: String) -> String? {
        guard let data = try? Data(contentsOf: url(for: account)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: url(for: account))
    }
}
