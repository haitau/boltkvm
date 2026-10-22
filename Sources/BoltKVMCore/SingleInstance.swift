import Foundation

/// One boltkvm per machine, per role.
///
/// Duplicate instances are not harmless: two servers fight over the virtual
/// display and the TCP port, two helpers fight over the same, and a leftover
/// helper from a crashed app will keep the display alive and block the new one.
/// The lock is an flock on a pid file, so the kernel releases it when the
/// process dies — including SIGKILL, so no stale-lock cleanup is needed.
enum SingleInstance {
    enum Lock: String {
        case app
        case server
    }

    /// Returns nil when the lock was taken, or the PID of the owner.
    static func acquire(_ lock: Lock) -> Int32? {
        guard let path = lockPath(lock) else { return nil }
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }  // can't lock: don't block startup
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let owner = readPID(path)
            close(fd)
            return owner ?? 0
        }
        ftruncate(fd, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        // Keep the descriptor open: closing it drops the lock.
        held.append(fd)
        return nil
    }

    private static var held: [Int32] = []

    private static func lockPath(_ lock: Lock) -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BoltKVM", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return base.appendingPathComponent("\(lock.rawValue).pid").path
    }

    private static func readPID(_ path: String) -> Int32? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }
}
