import Foundation
import CoreMedia
import CoreVideo
import Darwin
import AppKit
import ApplicationServices

func usage() -> Never {
    print("""
    boltkvm — M1 alpha-prime spike

    server:
      boltkvm server [--width 3840] [--height 2160] [--port 7474] [--seconds 20]
                     [--virtual-display external|builtin] [--virtual-display-size WxH]
                     [--bind auto|<ipv4>] [--codec prores|hevc] [--key <psk>|--insecure]
                     [--audio]   # 默认不传音频；加 --audio 才采集并转发

    client:
      boltkvm client [--host <mini>] [--port 7474] [--seconds 20] [--render] [--switch-mode] [--input] [--reconnect] [--key <psk>]
                     [--audio] [--audio-record <path>]   # 播放 / 落盘被控端音频

    utilities:
      boltkvm doctor [--role server|client]
      boltkvm inputprobe [--seconds 60] [--interval-ms 60000]
      boltkvm cryptotest      # 会话加密往返与篡改拒绝自测
      boltkvm displays        # 列出显示器状态（active/asleep/refresh）
                     [--display-id N]   # 强制采集指定显示器（调试用）
      boltkvm watchdog [--once] [--install] [--uninstall] [--interval 5]
      boltkvm selftest
      boltkvm pattern <png> [seconds]
    """)
    exit(2)
}

func argValue(_ args: [String], _ name: String, _ def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}

func argInt(_ args: [String], _ name: String, _ def: Int) -> Int {
    Int(argValue(args, name, String(def))) ?? def
}

/// Server side of the handshake: send a nonce, then wait for the matching MAC.
/// Packets that are not the response are skipped, because the client may have
/// queued a time-sync request before it saw the challenge.
func authenticateServer(conn: TCPConnection, key: Data, timeoutSeconds: Int = 5) throws {
    let nonce = randomNonce()
    try conn.send(packet(type: .authChallenge, ptsMicros: 0, payload: nonce))
    conn.setRecvTimeout(timeoutSeconds)
    defer { conn.setRecvTimeout(0) }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds) * 1_000_000_000
    let expected = authMAC(key: key, nonce: nonce)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let hd = try conn.recvExact(HEADER_SIZE)
        guard let h = PacketHeader.decode(hd) else { throw POSIXError(.EBADMSG) }
        let payload = try conn.recvExact(Int(h.payloadLength))
        if h.type == .authResponse {
            guard authMACMatches(expected, payload) else { throw POSIXError(.EACCES) }
            try conn.send(packet(type: .authOk, ptsMicros: 0, payload: Data()))
            // Auth ok is the last plaintext packet: everything after it is sealed.
            let keys = deriveSessionKeys(psk: key, nonce: nonce)
            conn.inCipher = SessionCipher(key: keys.c2s)
            conn.outCipher = SessionCipher(key: keys.s2c)
            return
        }
    }
    throw POSIXError(.ETIMEDOUT)
}

/// Installs the session ciphers once the server confirms auth. Both sides set
/// them at the same point (right after authOk), which keeps the nonce counters
/// aligned in each direction.
func enableClientEncryption(conn: TCPConnection, nonce: Data?) {
    guard let nonce, let key = resolveAuthKey(CommandLine.arguments) else { return }
    let keys = deriveSessionKeys(psk: key, nonce: nonce)
    conn.outCipher = SessionCipher(key: keys.c2s)
    conn.inCipher = SessionCipher(key: keys.s2c)
}

/// Client side of the handshake: answer the challenge with the MAC.
func respondToAuthChallenge(conn: TCPConnection, nonce: Data) throws {
    guard let key = resolveAuthKey(CommandLine.arguments) else {
        // Fatal on purpose: retrying cannot help and --reconnect would spin.
        log("server requires a pre-shared key: pass --key, set $BOLTKVM_KEY, or create ~/.boltkvm-key")
        exit(2)
    }
    let mac = authMAC(key: key, nonce: nonce)
    try conn.send(packet(type: .authResponse, ptsMicros: 0, payload: mac))
}

func timeSyncRequest() -> Data {
    packet(type: .timeSync, ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000), payload: Data())
}

func handleTimeSync(_ header: PacketHeader, _ payload: Data, decoder: VideoDecoder) {
    guard payload.count >= 8 else { return }
    let t1 = payload.readInt64BE(payload.startIndex)
    let t2 = header.ptsMicros
    let t3 = Int64(Date().timeIntervalSince1970 * 1_000_000)
    let offset = ((t2 - t1) + (t2 - t3)) / 2
    let rttMs = Double(t3 - t1) / 1000.0
    decoder.setClockOffset(offset, rttMs: rttMs)
    log("time sync rtt=\(rttMs)ms server-local offset=\(Double(offset) / 1000.0)ms")
}

func acceptAsync(_ listener: TCPListener) async throws -> TCPConnection {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TCPConnection, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do { cont.resume(returning: try listener.accept()) }
            catch { cont.resume(throwing: error) }
        }
    }
}

@main
struct BoltKVM {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage() }
        switch args[1] {
        case "server":
            // Creation has to happen on the main thread, so it runs here rather
            // than inside the async server loop.
            let virtualDisplay = prepareVirtualDisplay(args: args)
            await runServer(args, virtualDisplay: virtualDisplay)
        case "doctor":
            runDoctor(args)
        case "watchdog":
            Watchdog.run(args)
        case "selftest":
            runSelftest()
        case "inputprobe":
            await runInputProbe(args)
        case "cryptotest":
            runCryptoTest()
        case "displays":
            runDisplays()
        case "pattern":
            await runPattern(args)
        case "client":
            if args.contains("--render") {
                await runClientRender(args)
            } else {
                await runClient(args)
            }
        default:
            usage()
        }
    }

    static func runServer(_ args: [String], virtualDisplay: BuiltinVirtualDisplay? = nil) async {
        let width = argInt(args, "--width", 3840)
        let height = argInt(args, "--height", 2160)
        let port = UInt16(argInt(args, "--port", 7474))
        let seconds = Double(argInt(args, "--seconds", 0))
        let dump = argValue(args, "--dump", "")
        let codecName = argValue(args, "--codec", "prores")
        let codec: VideoCodec = codecName == "prores" ? .prores422 : .hevc
        let bindSpec = argValue(args, "--bind", "auto")
        let insecure = args.contains("--insecure")
        let authKey = resolveAuthKey(args)
        if authKey == nil && !insecure {
            log("refusing to start: no pre-shared key. Pass --key, set $BOLTKVM_KEY, or create ~/.boltkvm-key; use --insecure to override")
            exit(2)
        }
        if insecure { log("WARNING: --insecure — anyone who can reach this port controls the machine") }
        if let virtualDisplay {
            // Losing the display means capture is meaningless; exit and let the
            // supervisor recreate the process (and with it, the display).
            virtualDisplay.onLost = {
                log("virtual display: removed by the system; exiting so the supervisor can recreate it")
                exit(3)
            }
        }
        do {
            let listener = try TCPListener(port: port, bind: bindSpec)
            let deadline: UInt64? = seconds > 0
                ? DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
                : nil
            log("listening on \(listener.label):\(port) (\(seconds > 0 ? "\(Int(seconds))s total" : "forever")), auth=\(authKey == nil ? "OFF" : "psk"); waiting for client")
            while true {
                if let d = deadline, DispatchTime.now().uptimeNanoseconds >= d { break }
                let conn = try await acceptAsync(listener)
                log("client connected")
                if let key = authKey {
                    do {
                        try authenticateServer(conn: conn, key: key)
                        log("auth ok")
                    } catch {
                        log("auth failed: \(error); closing")
                        conn.close()
                        continue
                    }
                }
                let audio = args.contains("--audio")
        let server = Server(width: width, height: height, codec: codec, connection: conn,
                            dumpPath: dump.isEmpty ? nil : dump, audioEnabled: audio,
                            preferredDisplayID: argInt(args, "--display-id", 0) != 0
                                ? CGDirectDisplayID(argInt(args, "--display-id", 0))
                                : virtualDisplay?.displayID)
                do {
                    try await server.start()
                } catch {
                    log("session start failed: \(error)")
                    conn.close()
                    continue
                }
                while !server.isDisconnected {
                    if let d = deadline, DispatchTime.now().uptimeNanoseconds >= d { break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                await server.stop()
                server.reportLine()
                conn.close()
                log("session ended; accepting next client")
                if let d = deadline, DispatchTime.now().uptimeNanoseconds >= d { break }
            }
            listener.close()
            exit(0)
        } catch {
            log("server error: \(error)")
            exit(1)
        }
    }

    /// Posts an inert mouse move on a fixed cadence. Used to prove the input
    /// chain stays alive over a long run: the events are posted at the HID tap,
    /// so the client's CGEventTap sees them exactly like a physical mouse, and
    /// the server's captured-frame counter proves they landed on the other Mac
    /// (showsCursor is on, so a move changes pixels).
    static func runInputProbe(_ args: [String]) async {
        let seconds = Double(argInt(args, "--seconds", 60))
        let intervalMs = max(200, argInt(args, "--interval-ms", 60_000))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, seconds) * 1_000_000_000)
        log("inputprobe start seconds=\(Int(seconds)) interval=\(intervalMs)ms")
        var posted = 0
        var dx: CGFloat = 3
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let cur = CGEvent(source: nil)?.location else {
                log("inputprobe: cannot read cursor position (no session?)")
                exit(1)
            }
            let target = CGPoint(x: cur.x + dx, y: cur.y)
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: target, mouseButton: .left) else {
                log("inputprobe: cannot create event")
                exit(1)
            }
            ev.post(tap: .cghidEventTap)
            posted += 1
            log("inputprobe posted=\(posted) at=\(Int(target.x)),\(Int(target.y))")
            dx = -dx
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
        log("inputprobe done posted=\(posted)")
        exit(0)
    }

    static func runDoctor(_ args: [String]) {
        let role = argValue(args, "--role", "all")
        let screen = CGPreflightScreenCaptureAccess()
        let listen = CGPreflightListenEventAccess()
        let post = CGPreflightPostEventAccess()
        let ax = AXIsProcessTrusted()
        func mark(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }
        print("boltkvm doctor role=\(role)")
        print("\(mark(screen)) Screen Recording (CGPreflightScreenCaptureAccess)")
        print("\(mark(listen)) Input Monitoring / listen events (CGPreflightListenEventAccess)")
        print("\(mark(post)) Accessibility / post events (CGPreflightPostEventAccess)")
        print("\(mark(ax)) Accessibility trust (AXIsProcessTrusted)")
        var requiredOK = true
        if role == "server" || role == "all" {
            requiredOK = requiredOK && screen
            if !post { print("note: server input injection needs Accessibility") }
        }
        if role == "client" || role == "all" {
            requiredOK = requiredOK && listen
        }
        if !requiredOK {
            print("hint: System Settings > Privacy & Security > Screen Recording / Accessibility / Input Monitoring; grant to the app that launches boltkvm, then restart it.")
        }
        exit(requiredOK ? 0 : 1)
    }

    nonisolated(unsafe) static var patternTimer: Timer?
    nonisolated(unsafe) static var patternActivity: NSObjectProtocol?

    /// Round-trips the session cipher: both directions, many packets, and the
    /// three failure modes that matter (tampered body, tampered header, wrong
    /// key). No network, no TCC — run it after touching the crypto code.
    /// Every display with the flags that decide whether capture can keep up:
    /// a sleeping or inactive display delivers frames only when content changes.
    static func runDisplays() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        print("displays=\(count)")
        for id in ids.prefix(Int(count)) {
            let mode = CGDisplayCopyDisplayMode(id)
            let flags = [
                CGDisplayIsActive(id) != 0 ? "active" : "inactive",
                CGDisplayIsOnline(id) != 0 ? "online" : "offline",
                CGDisplayIsAsleep(id) != 0 ? "ASLEEP" : "awake",
                CGDisplayIsMain(id) != 0 ? "main" : "secondary",
            ].joined(separator: " ")
            print(String(format: "  id=%-3u %@ logical=%dx%d pixel=%dx%d refresh=%.0fHz bounds=%dx%d",
                         id, flags,
                         mode.map { $0.width } ?? 0, mode.map { $0.height } ?? 0,
                         mode.map { $0.pixelWidth } ?? 0, mode.map { $0.pixelHeight } ?? 0,
                         mode?.refreshRate ?? 0,
                         Int(CGDisplayBounds(id).width), Int(CGDisplayBounds(id).height)))
        }
    }

    static func runCryptoTest() {
        let psk = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let keys = deriveSessionKeys(psk: psk, nonce: nonce)
        var failures = 0

        let send = SessionCipher(key: keys.c2s)
        let recv = SessionCipher(key: keys.c2s)
        var lastFrame = Data()
        for i in 0..<1_000 {
            let body = Data((0..<(i % 500)).map { _ in UInt8.random(in: 0...255) })
            var frame = packet(type: .frame, flags: 0, ptsMicros: Int64(i), payload: body)
            frame = send.seal(frame)
            guard let head = PacketHeader.decode(frame.prefix(HEADER_SIZE)) else {
                print("FAIL: header decode at \(i)"); failures += 1; break
            }
            guard head.flags & FLAG_ENCRYPTED != 0 else {
                print("FAIL: encrypted flag missing at \(i)"); failures += 1; break
            }
            let opened = try? recv.open(header: Data(frame.prefix(HEADER_SIZE)), body: Data(frame.dropFirst(HEADER_SIZE)))
            if opened != body { print("FAIL: payload mismatch at \(i)"); failures += 1; break }
            lastFrame = frame
        }

        // Tampered body must fail authentication.
        var tampered = lastFrame
        tampered[tampered.count - 1] ^= 0xFF
        let bodyTamper = try? SessionCipher(key: keys.c2s).open(
            header: Data(tampered.prefix(HEADER_SIZE)), body: Data(tampered.dropFirst(HEADER_SIZE)))
        if bodyTamper != nil { print("FAIL: tampered body accepted"); failures += 1 }

        // Tampered header is AAD, so it must fail too.
        var headerTampered = lastFrame
        headerTampered[headerTampered.startIndex + 6] ^= 0x01
        let headerTamper = try? SessionCipher(key: keys.c2s).open(
            header: Data(headerTampered.prefix(HEADER_SIZE)), body: Data(headerTampered.dropFirst(HEADER_SIZE)))
        if headerTamper != nil { print("FAIL: tampered header accepted"); failures += 1 }

        // Wrong key must fail.
        let wrong = SessionCipher(key: deriveSessionKeys(psk: Data(repeating: 0, count: 32), nonce: nonce).c2s)
        let wrongKey = try? wrong.open(header: Data(lastFrame.prefix(HEADER_SIZE)),
                                       body: Data(lastFrame.dropFirst(HEADER_SIZE)))
        if wrongKey != nil { print("FAIL: wrong key accepted"); failures += 1 }

        print(failures == 0 ? "cryptotest PASS (1000 frames, 3 tamper cases)" : "cryptotest FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    static func runSelftest() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        let sets = [Data([0x40, 0x01, 0x0c]), Data([0x42, 0x01, 0x01]), Data([0x44, 0x01])]
        let hevc = StreamFormat(width: 3840, height: 2160, codec: .hevc, parameterSets: sets)
        if let f = StreamFormat.decode(hevc.encode()) {
            check(f.width == 3840 && f.height == 2160 && f.codec == .hevc, "hevc format width/height/codec")
            check(f.parameterSets == sets, "hevc parameter sets")
        } else { check(false, "hevc format decode") }

        let prores = StreamFormat(width: 3840, height: 2160, codec: .prores422, parameterSets: [])
        if let f = StreamFormat.decode(prores.encode()) {
            check(f.codec == .prores422 && f.parameterSets.isEmpty, "prores format decode")
        } else { check(false, "prores format decode") }

        let payload = Data(repeating: 0xAB, count: 1000)
        let pkt = packet(type: .frame, flags: 1, ptsMicros: 1_234_567_890, payload: payload)
        if let h = PacketHeader.decode(pkt.prefix(HEADER_SIZE)) {
            check(h.type == .frame && h.flags == 1 && h.payloadLength == 1000 && h.ptsMicros == 1_234_567_890, "packet header")
            check(pkt.count == HEADER_SIZE + 1000, "packet length")
            check(pkt.suffix(1000) == payload, "packet payload")
        } else { check(false, "packet header decode") }

        let ie = InputEvent(type: .scroll, keyCode: 12, flags: 0x1234, x: 0.25, y: 0.75,
                            button: 2, scrollX: -3.5, scrollY: 4.25, phase: 2, momentum: 1, isRepeat: true)
        if let back = InputEvent.decode(ie.encode()) {
            check(back.type == .scroll && back.keyCode == 12 && back.flags == 0x1234, "input type/key/flags")
            check(back.x == 0.25 && back.y == 0.75 && back.button == 2, "input position/button")
            check(back.scrollX == -3.5 && back.scrollY == 4.25 && back.phase == 2 && back.momentum == 1 && back.isRepeat, "input scroll/phase")
        } else { check(false, "input event decode") }

        for n in [0, 1, 7, 8, 9, 12, 13, 100] {
            var d = Data(count: n)
            for i in 0..<n { d[i] = UInt8(i & 0xff) }
            let back = StreamFormat.decode(d)
            check(back == nil, "truncated format \(n) rejected")
        }

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func runPattern(_ args: [String]) async {
        guard args.count >= 3 else {
            print("usage: boltkvm pattern <png> [seconds]")
            exit(2)
        }
        let path = args[2]
        let seconds = args.count > 3 ? Double(args[3]) ?? 0 : 0
        NSApplication.shared.setActivationPolicy(.regular)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 3008, height: 1692)
        let w = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        patternActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: "boltkvm test pattern"
        )
        let iv = NSImageView(frame: screen)
        iv.imageScaling = .scaleAxesIndependently
        iv.image = NSImage(contentsOfFile: path)
        // A small moving square keeps ScreenCaptureKit delivering frames even
        // when the test pattern itself is static.
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.red.cgColor
        iv.addSubview(dot)
        var tick = 0
        let timer = Timer(timeInterval: 1.0/60.0, repeats: true) { _ in
            tick = (tick + 11) % Int(screen.width)
            dot.frame.origin.x = CGFloat(tick)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.patternTimer = timer
        w.contentView = iv
        NSApplication.shared.presentationOptions = [.hideDock, .hideMenuBar]
        w.orderFrontRegardless()
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApplication.shared.terminate(nil)
            }
        }
        NSApplication.shared.run()
    }

    @MainActor
    static func runClientRender(_ args: [String]) async {
        let host = argValue(args, "--host", "127.0.0.1")
        let port = UInt16(argInt(args, "--port", 7474))
        let seconds = Double(argInt(args, "--seconds", 20))
        let switchMode = args.contains("--switch-mode")
        let wantsInput = args.contains("--input")
        let reconnect = args.contains("--reconnect")
        let audioRecord = argValue(args, "--audio-record", "")
        let wantsAudio = args.contains("--audio") || !audioRecord.isEmpty
        let audio: AudioPlayer? = wantsAudio
            ? AudioPlayer(play: args.contains("--audio"), recordPath: audioRecord.isEmpty ? nil : audioRecord)
            : nil

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = RenderSession.shared
        RenderSession.shared.start(switchMode: switchMode)

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            var lastDecoder: VideoDecoder?
            var packets = 0
            var frames = 0
            var reconnects = 0
            var winBytes = 0
            var winFrames = 0
            var lastBeat = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds < deadline {
                var conn: TCPConnection?
                var sawChallenge = false
                var sawAuthOk = false
                var challengeNonce: Data?
                do {
                    let c = try tcpConnect(host: host, port: port)
                    conn = c
                    log("connected to \(host):\(port)")
                    try c.send(timeSyncRequest())
                    let decoder = VideoDecoder()
                    decoder.renderer = RenderSession.shared.renderer
                    lastDecoder = decoder
                    var inputStarted = false
                    while DispatchTime.now().uptimeNanoseconds < deadline {
                        let (header, payload) = try c.recvFrame()
                        packets += 1
                        winBytes += payload.count
                        if header.type == .frame { frames += 1; winFrames += 1 }
                        let beatNow = DispatchTime.now().uptimeNanoseconds
                        if beatNow - lastBeat >= 60_000_000_000 {
                            let secs = Double(beatNow - lastBeat) / 1e9
                            let mbps = secs > 0 ? Double(winBytes) * 8 / secs / 1e6 : 0
                            let kbFrame = winFrames > 0 ? Double(winBytes) / Double(winFrames) / 1024 : 0
                            let budget = Renderer.budget(forFrameKB: kbFrame)
                            RenderSession.shared.renderer?.setBudget(budget)
                            lastBeat = beatNow
                            log(String(format: "loop.win packets=%d frames=%d reconnects=%d mbps=%.1f kbFrame=%.0f budget=%.0fms",
                                       packets, frames, reconnects, mbps, kbFrame, budget))
                            winBytes = 0
                            winFrames = 0
                        }
                        if header.type == .authChallenge {
                            sawChallenge = true
                            challengeNonce = payload
                            try respondToAuthChallenge(conn: c, nonce: payload)
                        } else if header.type == .authOk {
                            sawAuthOk = true
                            enableClientEncryption(conn: c, nonce: challengeNonce)
                            log("auth ok")
                            // Encrypted ping: proves the client->server direction
                            // decrypts, not just server->client.
                            try? c.send(timeSyncRequest())
                        } else if header.type == .format, let f = StreamFormat.decode(payload) {
                            try decoder.configure(f)
                            if wantsInput && !inputStarted {
                                inputStarted = true
                                DispatchQueue.main.async {
                                    RenderSession.shared.restartInput(conn: c)
                                }
                            }
                        } else if header.type == .frame {
                            decoder.decode(payload, ptsMicros: header.ptsMicros)
                        } else if header.type == .timeSync {
                            handleTimeSync(header, payload, decoder: decoder)
                        } else if header.type == .audio {
                            audio?.enqueue(payload)
                        }
                    }
                    c.close()
                    break
                } catch {
                    if sawChallenge && !sawAuthOk {
                        // Wrong key: the server closed after the challenge. Retrying
                        // with the same key cannot succeed.
                        log("auth rejected by server: check ~/.boltkvm-key on both ends (not retrying)")
                        break
                    }
                    reconnects += 1
                    log("client render error: \(error) (reconnect \(reconnects))")
                    conn?.close()
                    DispatchQueue.main.async { RenderSession.shared.stopInput() }
                    if !reconnect { break }
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
            sleep(1)
            audio?.finish()
            lastDecoder?.report()
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
        NSApplication.shared.run()
    }

    static func runClient(_ args: [String]) async {
        let host = argValue(args, "--host", "127.0.0.1")
        let port = UInt16(argInt(args, "--port", 7474))
        let seconds = Double(argInt(args, "--seconds", 20))
        let audioRecord = argValue(args, "--audio-record", "")
        let audio: AudioPlayer? = (args.contains("--audio") || !audioRecord.isEmpty)
            ? AudioPlayer(play: args.contains("--audio"), recordPath: audioRecord.isEmpty ? nil : audioRecord)
            : nil
        do {
            let conn = try tcpConnect(host: host, port: port)
            log("connected to \(host):\(port)")
            try conn.send(timeSyncRequest())
            let decoder = VideoDecoder()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            var received = 0
            var packets = 0
            var lastHeader: PacketHeader?
            var challengeNonce: Data?
            var lastBeat = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds < deadline {
                do {
                    let (header, payload) = try conn.recvFrame()
                    lastHeader = header
                    packets += 1
                    let beatNow = DispatchTime.now().uptimeNanoseconds
                    if beatNow - lastBeat >= 60_000_000_000 {
                        lastBeat = beatNow
                        log("loop.win packets=\(packets) received=\(received)")
                    }
                    switch header.type {
                    case .format:
                        if let f = StreamFormat.decode(payload) {
                            try decoder.configure(f)
                        }
                    case .frame:
                        received += 1
                        decoder.decode(payload, ptsMicros: header.ptsMicros)
                    case .heartbeat:
                        break
                    case .timeSync:
                        handleTimeSync(header, payload, decoder: decoder)
                    case .authChallenge:
                        challengeNonce = payload
                        try respondToAuthChallenge(conn: conn, nonce: payload)
                    case .authOk:
                        enableClientEncryption(conn: conn, nonce: challengeNonce)
                        log("auth ok")
                        try? conn.send(timeSyncRequest())
                    case .input, .authResponse:
                        break
                    case .audio:
                        audio?.enqueue(payload)
                    }
                } catch {
                    log("client read error: \(error)")
                    break
                }
            }
            audio?.finish()
            decoder.report()
            log("received frames=\(received) lastType=\(String(describing: lastHeader?.type))")
            conn.close()
            exit(0)
        } catch {
            log("client error: \(error)")
            exit(1)
        }
    }
}
