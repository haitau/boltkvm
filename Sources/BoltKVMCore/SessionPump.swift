import Foundation

/// The packet loop both clients share: authenticate, then feed the decoder and
/// report counters. Everything UI- or CLI-specific — state changes, config
/// requests, stats formatting — is a callback, so the wire behaviour lives in
/// one place instead of two nearly identical loops (B8).
final class SessionPump {
    /// Traffic since the previous `onWindow` call (roughly one second).
    struct Window {
        let packets: Int
        let frames: Int
        let bytes: Int
        let seconds: Double

        var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }
        var mbps: Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1e6 : 0 }
    }

    var onChallenge: ((Data) throws -> Void)?
    var onAuthOk: ((PacketHeader, Data) throws -> Void)?
    var onFormat: ((StreamFormat) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onClipboard: ((Data) -> Void)?
    var onFileTransfer: ((Data) -> Void)?
    var onWindow: ((Window) -> Void)?
    /// Lifetime totals every 60 s; the CLI smoke test uses it to prove the loop
    /// is still alive on a quiet screen.
    var onLongWindow: ((_ packets: Int, _ frames: Int) -> Void)?

    let decoder: VideoDecoder
    private let conn: TCPConnection
    private(set) var lastType: PacketType?
    /// Lifetime totals, for the caller's final report.
    private(set) var packets = 0
    private(set) var frames = 0

    init(conn: TCPConnection, decoder: VideoDecoder) {
        self.conn = conn
        self.decoder = decoder
    }

    /// Runs until the connection fails or `deadline` passes. Throws the socket
    /// error so the caller can decide whether it means "wrong key" (CLI/app
    /// state) or an ordinary disconnect.
    func run(deadline: DispatchTime? = nil) throws {
        // Keep-alive in the client→server direction: the server's read loop only
        // sees input when the user acts, so without a periodic packet an idle
        // session would look dead to a read timeout.
        let ping = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "boltkvm.clock.ping"))
        ping.schedule(deadline: .now() + 3, repeating: 3)
        ping.setEventHandler { [conn] in _ = try? conn.send(timeSyncRequest()) }
        ping.resume()
        defer { ping.cancel() }

        var winPackets = 0, winFrames = 0, winBytes = 0
        var last = DispatchTime.now().uptimeNanoseconds
        var lastLong = last
        while true {
            if let deadline, DispatchTime.now() >= deadline { return }
            let (header, payload) = try conn.recvFrame()
            lastType = header.type
            packets += 1
            winPackets += 1
            winBytes += payload.count
            switch header.type {
            case .command, .input, .config, .authExchange, .authResponse, .heartbeat, .unknown:
                break  // client never receives these, needs no action, or predates us
            case .authChallenge:
                try onChallenge?(payload)
            case .authOk:
                try onAuthOk?(header, payload)
            case .format:
                if let f = StreamFormat.decode(payload) {
                    try decoder.configure(f)
                    onFormat?(f)
                }
            case .frame:
                frames += 1
                winFrames += 1
                decoder.decode(payload, ptsMicros: header.ptsMicros)
            case .audio:
                onAudio?(payload)
            case .clipboard:
                onClipboard?(payload)
            case .fileTransfer:
                onFileTransfer?(payload)
            case .timeSync:
                handleTimeSync(header, payload, decoder: decoder)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - last >= 1_000_000_000 {
                onWindow?(Window(packets: winPackets, frames: winFrames,
                                 bytes: winBytes, seconds: Double(now - last) / 1e9))
                winPackets = 0; winFrames = 0; winBytes = 0
                last = now
            }
            if now - lastLong >= 60_000_000_000 {
                lastLong = now
                onLongWindow?(packets, frames)
            }
        }
    }
}
