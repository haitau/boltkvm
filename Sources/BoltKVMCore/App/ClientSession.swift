import AppKit
import Foundation

/// Client-side connection engine: connect → auth → decode → present, plus input
/// forwarding and audio. Same wire logic as `boltkvm client --render`, minus the
/// borderless fullscreen window the CLI builds for long runs.
final class ClientSession {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "正在连接…"
            case .streaming: return "已连接"
            case .failed(let why): return "失败：\(why)"
            }
        }
    }

    var onState: ((State) -> Void)?
    var onStats: ((String) -> Void)?

    private(set) var renderer: Renderer
    private var task: Task<Void, Never>?
    private var conn: TCPConnection?
    private var input: InputCapture?
    private var audio: AudioPlayer?
    private var decoder: VideoDecoder?

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    var isActive: Bool { task != nil }

    func connect(host: String, port: UInt16, key: Data?, forwardInput: Bool, playAudio: Bool) {
        disconnect()
        // --key on the CLI, $BOLTKVM_KEY, then ~/.boltkvm-key; the app never exits
        // when the key is missing, it just reports it in the status line.
        guard let sessionKey = key ?? resolveAuthKey([]) else {
            setState(.failed("缺少预共享密钥（~/.boltkvm-key）"))
            return
        }
        if playAudio {
            audio = AudioPlayer(play: true, recordPath: nil)
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.setState(.connecting)
            var frames = 0
            var bytes = 0
            var lastReport = DispatchTime.now().uptimeNanoseconds
            do {
                let c = try tcpConnect(host: host, port: port)
                self.conn = c
                defer { c.close() }
                try c.send(timeSyncRequest())
                let decoder = VideoDecoder()
                decoder.renderer = self.renderer
                self.decoder = decoder
                var challengeNonce: Data?
                var wantInput = forwardInput
                while !Task.isCancelled {
                    let (header, payload) = try c.recvFrame()
                    bytes += payload.count
                    switch header.type {
                    case .authChallenge:
                        challengeNonce = payload
                        try respondToAuthChallenge(conn: c, nonce: payload, key: sessionKey)
                    case .authOk:
                        if let challengeNonce {
                            enableClientEncryption(conn: c, nonce: challengeNonce, key: sessionKey)
                        }
                        // Encrypted ping: proves the client→server direction
                        // decrypts too, not just server→client.
                        try? c.send(timeSyncRequest())
                    case .format:
                        if let format = StreamFormat.decode(payload) {
                            try decoder.configure(format)
                            self.setState(.streaming)
                            if wantInput {
                                wantInput = false
                                DispatchQueue.main.async { self.startInput(conn: c) }
                            }
                        }
                    case .frame:
                        frames += 1
                        decoder.decode(payload, ptsMicros: header.ptsMicros)
                    case .audio:
                        self.audio?.enqueue(payload)
                    case .timeSync:
                        handleTimeSync(header, payload, decoder: decoder)
                    case .heartbeat, .input, .authResponse:
                        break
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now - lastReport >= 1_000_000_000 {
                        let secs = Double(now - lastReport) / 1e9
                        let fps = Double(frames) / secs
                        let mbps = Double(bytes) * 8 / secs / 1e6
                        self.onStats?(String(format: "%.0f fps · %.0f Mbps · %@",
                                             fps, mbps, host))
                        frames = 0
                        bytes = 0
                        lastReport = now
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.setState(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func startInput(conn: TCPConnection) {
        guard input == nil else { return }
        let capture = InputCapture(conn: conn)
        if capture.start() {
            input = capture
        } else {
            log("input: not started (Input Monitoring permission?)")
        }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        conn?.close()
        conn = nil
        input?.stop()
        input = nil
        audio?.finish()
        audio = nil
        decoder?.report()
        decoder = nil
        // Presentation is a separate leg from decoding: report it too, otherwise
        // "connected, frames arriving" can hide a black window.
        renderer.report()
        setState(.idle)
        onStats?("")
    }

    private func setState(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            self?.onState?(state)
        }
    }
}
