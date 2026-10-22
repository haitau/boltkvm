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
            case .idle: return L.t("client.state.idle")
            case .connecting: return L.t("client.state.connecting")
            case .streaming: return L.t("client.state.streaming")
            case .failed(let why): return L.f("client.state.failed", why)
            }
        }
    }

    var onState: ((State) -> Void)?
    var onStats: ((String) -> Void)?

    private(set) var renderer: Renderer
    private var task: Task<Void, Never>?
    private var conn: TCPConnection?
    private var input: InputCapture?
    private var windowInput: WindowInputCapture?
    /// Window the remote picture is drawn into; when set, input is captured
    /// with a local NSEvent monitor (no Input Monitoring permission needed).
    weak var inputView: NSView?
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
            setState(.failed(L.t("client.key.missing")))
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
                // The first socket of a freshly launched app can be refused by
                // the Local Network privacy check ("No route to host") while the
                // check is still settling; retry briefly instead of showing an
                // error the user would read as "the server is down".
                var connection: TCPConnection?
                for attempt in 1...3 {
                    do {
                        connection = try tcpConnect(host: host, port: port)
                        break
                    } catch {
                        if attempt == 3 { throw error }
                        log("connect: attempt \(attempt) failed (\(error.localizedDescription)); retrying")
                        Thread.sleep(forTimeInterval: 0.6)
                    }
                }
                guard let c = connection else { return }
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
        guard input == nil, windowInput == nil else { return }
        if let view = inputView {
            let capture = WindowInputCapture(conn: conn, view: view)
            if capture.start() {
                windowInput = capture
                return
            }
        }
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
        windowInput?.stop()
        windowInput = nil
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
