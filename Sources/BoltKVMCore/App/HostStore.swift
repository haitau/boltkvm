import Foundation

/// One saved remote Mac, as shown in the connection list (R1).
///
/// Secrets are never stored here: `pskKeychainAccount` is only the *name* of a
/// Keychain item (`service = boltkvm-psk`), nil meaning "use ~/.boltkvm-key".
struct SavedHost: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var pskKeychainAccount: String?
    /// nil means "whatever the server starts with".
    var width: Int?
    var height: Int?
    /// nil keeps the old global preference; the editor sets these explicitly.
    var forwardInput: Bool?
    var audio: Bool?
    var lastConnected: Date?

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 7474,
         pskKeychainAccount: String? = nil, width: Int? = nil, height: Int? = nil,
         forwardInput: Bool? = nil, audio: Bool? = nil,
         lastConnected: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.pskKeychainAccount = pskKeychainAccount
        self.width = width
        self.height = height
        self.forwardInput = forwardInput
        self.audio = audio
        self.lastConnected = lastConnected
    }
}

/// Persistence for the connection list. Small enough that a JSON file rewritten
/// on every change is simpler than a database, and it keeps the file inspectable.
final class HostStore {
    static let shared = HostStore()

    private let fileURL: URL
    private var items: [SavedHost] = []

    /// - Parameter directory: overridable so tests do not touch the real list.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask)[0]
            .appendingPathComponent("BoltKVM", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("hosts.json")
        reload()
    }

    var hosts: [SavedHost] { items }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        let decoder = JSONDecoder()
        // Must mirror the encoder below, otherwise every date fails to decode and
        // the whole list silently reloads as empty.
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([SavedHost].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    @discardableResult
    func add(_ host: SavedHost) -> SavedHost {
        items.append(host)
        persist()
        return host
    }

    func update(_ host: SavedHost) {
        guard let index = items.firstIndex(where: { $0.id == host.id }) else { return }
        items[index] = host
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Records a successful connection so the list can sort by recency.
    func touch(id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastConnected = date
        persist()
    }

    /// First launch after the upgrade: turn the old single host/port into one
    /// record, then forget the old keys so they cannot drift apart again.
    /// Returns true when a record was created.
    @discardableResult
    func migrateLegacySingleHost(_ host: String, port: UInt16) -> Bool {
        guard items.isEmpty, !host.isEmpty else { return false }
        add(SavedHost(name: host, host: host, port: port))
        return true
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
