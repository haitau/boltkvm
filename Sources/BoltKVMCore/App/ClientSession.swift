import AppKit
import Foundation

/// Client-side connection engine: connect → auth → decode → present, plus input
/// forwarding and audio. Same wire logic as `boltkvm client --render`, minus the
/// borderless fullscreen window the CLI builds for long runs.
final class ClientSession: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case connecting
        case reconnecting(Int)
        case streaming
        case failed(String)

        var text: String {
            switch self {
            case .idle: return L.t("client.state.idle")
            case .connecting: return L.t("client.state.connecting")
            case .reconnecting(let attempt): return L.f("client.state.reconnecting", attempt)
            case .streaming: return L.t("client.state.streaming")
            case .failed(let why): return L.f("client.state.failed", why)
            }
        }
    }

    var onState: ((State) -> Void)?
    var onStats: ((String) -> Void)?
    /// Fires after the connection task has fully unwound (success or failure),
    /// so the window can stop its timers and offer 连接 again.
    var onEnd: (() -> Void)?

    private(set) var renderer: Renderer
    private var task: Task<Void, Never>?
    private var conn: TCPConnection?
    private var input: InputCapture?
    private var windowInput: WindowInputCapture?
    /// Window the remote picture is drawn into; when set, input is captured
    /// with a local NSEvent monitor (no Input Monitoring permission needed).
    weak var inputView: NSView?
    private var audio: AudioPlayer?
    private var clipboard: ClipboardSync?
    private var decoder: VideoDecoder?
    private(set) var state: State = .idle
    /// Bumped by every connect/disconnect. A detached task compares it after
    /// each blocking step: a window closed or a role switched mid-connect must
    /// not leave a live session behind that nobody can disconnect.
    private var generation = 0
    private let lifecycleLock = NSLock()

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    var isActive: Bool { task != nil }

    private func bumpGeneration() -> Int {
        lifecycleLock.lock()
        generation += 1
        let g = generation
        lifecycleLock.unlock()
        return g
    }

    private func isCurrent(_ g: Int) -> Bool {
        lifecycleLock.lock()
        let ok = g == generation
        lifecycleLock.unlock()
        return ok
    }

    /// What the server should stream, when the user picked a size for this host.
    var requestedConfig: SessionConfig?
    /// Real stream size, reported once the server describes its format.
    var onFormat: ((Int, Int, ColorMode) -> Void)?

    func connect(host: String, port: UInt16, key: Data?, forwardInput: Bool, playAudio: Bool,
                 shareClipboard: Bool = true) {
        disconnect()
        let gen = bumpGeneration()
        // --key on the CLI, $BOLTKVM_KEY, then ~/.boltkvm-key; the app never exits
        // when the key is missing, it just reports it in the status line.
        guard let sessionKey = key ?? resolveAuthKey([]) else {
            setState(.failed(L.t("client.key.missing")))
            return
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            var attempt = 0
            // A resolution change restarts the controlled Mac's capture helper,
            // so the TCP session ends even though this window is still open.
            // Without this loop the window kept the last frame forever; retrying
            // turns that into a short "reconnecting" pause.
            while !Task.isCancelled, self.isCurrent(gen) {
                if attempt > 0 {
                    self.setState(.reconnecting(attempt))
                    // 0.5 s, 1 s, 2 s, 4 s, then 5 s between attempts.
                    let delay = min(5.0, 0.5 * Double(1 << min(attempt - 1, 4)))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, self.isCurrent(gen) else { return }
                }
                attempt += 1
                let audio = playAudio ? AudioPlayer(play: true, recordPath: nil) : nil
                self.audio = audio
                var gotAuthOk = false
                var sentAuthResponse = false
                var authRejected = false
                var endedNormally = false
                do {
                    self.setState(.connecting)
                    // The first socket of a freshly launched app can be refused
                    // by the Local Network privacy check ("No route to host")
                    // while the check is still settling; retry briefly instead
                    // of showing an error the user would read as "server down".
                    var connection: TCPConnection?
                    for connectAttempt in 1...3 {
                        if Task.isCancelled || !self.isCurrent(gen) { return }
                        do {
                            connection = try tcpConnect(host: host, port: port)
                            break
                        } catch {
                            if connectAttempt == 3 { throw error }
                            log("connect: attempt \(connectAttempt) failed (\(error.localizedDescription)); retrying")
                            try? await Task.sleep(nanoseconds: 600_000_000)
                        }
                    }
                    guard let c = connection else { return }
                    // The user may have closed the window while the handshake was
                    // settling; publishing the connection now would make it outlive
                    // the session that owns it.
                    guard self.isCurrent(gen), !Task.isCancelled else { c.close(); return }
                    self.conn = c
                    defer { c.close() }
                    try c.send(timeSyncRequest())
                    let decoder = VideoDecoder()
                    decoder.renderer = self.renderer
                    self.decoder = decoder
                    var challengeNonce: Data?
                    var wantInput = forwardInput
                    var authResponseSentAt: Int64 = 0
                    let pump = SessionPump(conn: c, decoder: decoder)
                    pump.onClipboard = { [weak self] payload in self?.clipboard?.handleClipboard(payload) }
                    pump.onFileTransfer = { [weak self] payload in self?.clipboard?.handleFile(payload) }
                    pump.onChallenge = { payload in
                        challengeNonce = payload
                        authResponseSentAt = Int64(Date().timeIntervalSince1970 * 1_000_000)
                        try respondToAuthChallenge(conn: c, nonce: payload, key: sessionKey)
                        sentAuthResponse = true
                    }
                    pump.onAuthOk = { header, payload in
                        gotAuthOk = true
                        // Only new servers advertise it; talking to an old one we
                        // must not send a packet type it cannot parse.
                        let supportsConfig = payload.first == 1
                        // Offset from the handshake: this packet was written by the
                        // server before it had a single frame to queue.
                        if supportsConfig, payload.count >= 9, authResponseSentAt > 0 {
                            let t2 = payload.readInt64BE(payload.startIndex + 1)
                            let t3 = Int64(Date().timeIntervalSince1970 * 1_000_000)
                            let offset = t2 - (authResponseSentAt + t3) / 2
                            let rtt = Double(t3 - authResponseSentAt) / 1000.0
                            decoder.setClockOffset(offset, rttMs: rtt)
                        }
                        if let challengeNonce {
                            try enableClientEncryption(
                                conn: c, nonce: challengeNonce, key: sessionKey,
                                forwardSecrecy: authOkFlags(payload) & FLAG_SUPPORTS_KEY_EXCHANGE != 0)
                        }
                        // A-2: the client's output device moved while it is
                        // playing the forwarded audio. Tell the server to pause
                        // its current Now Playing app, so music does not keep
                        // running on a speaker nobody is listening to.
                        audio?.onOutputRouteChange = { [weak c] in
                            guard let c else { return }
                            do {
                                try c.send(packet(type: .command,
                                                  payload: Data([RemoteAction.pauseMedia.rawValue])))
                                log("audio: output route changed; asked server to pause media")
                            } catch {
                                log("audio: could not send pause request: \(error)")
                            }
                        }
                        // Ask for the size the connection list chose *before*
                        // anything else: the server reads exactly one frame here.
                        if supportsConfig, let requested = self.requestedConfig {
                            log("sending config \(requested.width)x\(requested.height) quality=\(requested.quality) colour=\(requested.color)")
                            try? c.send(packet(type: .config, payload: requested.encode()))
                        }
                        // Encrypted ping: proves the client→server direction
                        // decrypts too, not just server→client.
                        try? c.send(timeSyncRequest())
                        if shareClipboard {
                            let sync = ClipboardSync(conn: c, enabled: true)
                            sync.start()
                            self.clipboard = sync
                        }
                    }
                    pump.onFormat = { format in
                        let size = (format.width, format.height)
                        DispatchQueue.main.async {
                            self.renderer.setColorMode(format.color)
                            self.onFormat?(size.0, size.1, format.color)
                        }
                        self.setState(.streaming)
                        if wantInput {
                            wantInput = false
                            DispatchQueue.main.async { self.startInput(conn: c) }
                        }
                    }
                    pump.onAudio = { [audio] payload in audio?.enqueue(payload) }
                    pump.onWindow = { window in
                        // The host is already in the connect bar; the toolbar only
                        // carries the live numbers. This runs on the pump thread and
                        // the handler touches NSTextFields, so hop to main.
                        let text = String(format: "%.0f fps · %.0f Mbps", window.fps, window.mbps)
                        DispatchQueue.main.async { self.onStats?(text) }
                    }
                    try pump.run()
                    endedNormally = true
                } catch {
                    if !Task.isCancelled && self.isCurrent(gen) {
                        // A reset right after we answered the challenge almost
                        // always means the key is wrong: the server closes without
                        // a word and retrying would only repeat the failure.
                        if sentAuthResponse && !gotAuthOk {
                            authRejected = true
                            self.setState(.failed(L.f("client.state.badKey", error.localizedDescription)))
                        } else {
                            log("session: \(error.localizedDescription); reconnecting")
                        }
                    }
                }
                // Per-attempt teardown. Keep the window and the renderer alive;
                // the next attempt reuses them.
                self.conn = nil
                self.decoder?.report()
                self.decoder = nil
                self.input?.stop()
                self.input = nil
                self.windowInput?.stop()
                self.windowInput = nil
                self.clipboard?.stop()
                self.clipboard = nil
                self.audio?.finish()
                self.audio = nil
                if authRejected { break }
                if Task.isCancelled || !self.isCurrent(gen) { return }
                if endedNormally { log("server closed the session; reconnecting") }
            }
            self.finish(gen: gen)
        }
    }

    /// Unwind a connection task: whatever ended it, the session must not stay
    /// "active" with a dead connection and a timer still polling it.
    private func finish(gen: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.task = nil
            self.conn = nil
            self.input?.stop()
            self.input = nil
            self.windowInput?.stop()
            self.windowInput = nil
            self.clipboard?.stop()
            self.clipboard = nil
            self.audio?.finish()
            self.audio = nil
            self.decoder = nil
            self.onStats?("")
            if case .failed = self.state {} else { self.setState(.idle) }
            self.onEnd?()
        }
    }

    private func startInput(conn: TCPConnection) {
        guard input == nil, windowInput == nil else { return }
        if let view = inputView {
            let capture = WindowInputCapture(conn: conn, view: view)
            capture.aspectProvider = { [weak self] in self?.renderer.imageAspect ?? 0 }
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

    /// Turn pointer/keyboard forwarding on or off mid-session (toolbar 控制).
    func setInputEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let conn = self.conn, self.isActive else { return }
            if enabled {
                self.startInput(conn: conn)
            } else {
                self.windowInput?.stop()
                self.windowInput = nil
                self.input?.stop()
                self.input = nil
            }
        }
    }

    var isForwardingInput: Bool { windowInput != nil || input != nil }

    /// Ask the remote to perform a system-UI action (Mission Control, …).
    /// Keystrokes cannot do this: macOS ignores synthetic events for its own
    /// hotkeys, so the server performs the action itself.
    func sendCommand(_ action: RemoteAction) {
        guard let conn, isActive else { return }
        do {
            try conn.send(packet(type: .command, payload: Data([action.rawValue])))
            log("command: sent \(action)")
        } catch {
            log("command: send failed: \(error)")
        }
    }

    func disconnect() {
        _ = bumpGeneration()
        task?.cancel()
        task = nil
        conn?.close()
        conn = nil
        input?.stop()
        input = nil
        windowInput?.stop()
        windowInput = nil
        clipboard?.stop()
        clipboard = nil
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
            guard let self else { return }
            self.state = state
            self.onState?(state)
        }
    }
}
