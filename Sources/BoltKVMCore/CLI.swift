import Foundation
import CoreMedia
import CoreVideo
import Darwin
import AppKit
import ApplicationServices
import Carbon

/// The process owns the virtual display, and `exit()` does not run Swift
/// deinits. A helper killed with SIGTERM therefore leaves its display in the
/// system's list with the same identity, and the replacement helper is refused
/// for up to 20 s — exactly the gap a resolution change cannot afford. Release
/// the display explicitly on every exit path (normal exit, SIGTERM/SIGINT, stdin
/// EOF and the display-lost callback all end in `exit`).
nonisolated(unsafe) private var displayToRelease: BuiltinVirtualDisplay?
nonisolated(unsafe) private var terminationSources: [DispatchSourceSignal] = []
nonisolated(unsafe) private var displayCleanupInstalled = false

/// The helper is a child of the app and lives inside the app bundle, so
/// LaunchServices otherwise treats it as a second foreground app with the same
/// bundle id, showing a second Dock icon. It is a background service.
private func becomeBackgroundApp() {
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
    let status = TransformProcessType(
        &psn,
        ProcessApplicationTransformState(kProcessTransformToBackgroundApplication)
    )
    if status != noErr { log("process: could not switch to background app (status \(status))") }
}

private func installDisplayCleanup(_ display: BuiltinVirtualDisplay) {
    displayToRelease = display
    guard !displayCleanupInstalled else { return }
    displayCleanupInstalled = true
    atexit {
        displayToRelease?.stop()
        displayToRelease = nil
    }
}

private func installTerminationSignalHandling() {
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log("terminating: releasing the virtual display")
            displayToRelease?.stop()
            displayToRelease = nil
            exit(0)
        }
        source.resume()
        terminationSources.append(source)
    }
}

/// 4 GB is the protocol's hard ceiling for one non-file item; larger user
/// values are clamped instead of overflowing the UInt32 length field.
private func clipboardMaxItemBytes(_ args: [String]) -> Int {
    min(max(1, argInt(args, "--clipboard-max-mb", 512)), 4095) << 20
}

/// 0 means "disk minus the reserve". Cap the user value so the GB→byte shift
/// cannot overflow.
private func clipboardMaxTransferBytes(_ args: [String]) -> Int64 {
    Int64(min(max(0, argInt(args, "--clipboard-max-gb", 0)), 1_000_000)) << 30
}

/// A-2: the CLI client uses the same route-change pause hook as the GUI
/// client, so a headless session behaves like the app when headphones move.
private func installPauseOnRouteChange(_ audio: AudioPlayer?, conn: TCPConnection) {
    audio?.onOutputRouteChange = { [weak conn] in
        guard let conn else { return }
        do {
            try conn.send(packet(type: .command,
                                 payload: Data([RemoteAction.pauseMedia.rawValue])))
            log("audio: output route changed; asked server to pause media")
        } catch {
            log("audio: could not send pause request: \(error)")
        }
    }
}

public enum CLI {

    public static func runServer(_ args: [String]) async {
        // A previous helper may have been killed while it had muted the local
        // output for a client. Restore it before doing anything else.
        AudioOutputMute.restoreStaleState()
        // The helper lives inside BoltKVM.app/Contents/MacOS, so LaunchServices
        // otherwise registers it with the app's bundle id as a second
        // foreground app — a second Dock icon next to the real one.
        becomeBackgroundApp()
        if let owner = SingleInstance.acquire(.server) {
            FileHandle.standardError.write(Data("boltkvm: another server is already running (pid \(owner))\n".utf8))
            exit(9)
        }
        installTerminationSignalHandling()
        exitWhenParentGoesAway()
        // Held for the process lifetime; a sleeping display means no frames.
        let sleepAssertion = DisplaySleepAssertion(reason: "BoltKVM is serving a remote screen")
        defer { sleepAssertion.release() }
        // Creation must happen on the main thread, so hop there before the
        // async server loop starts.
        var virtualDisplay = await MainActor.run { prepareVirtualDisplay(args: args) }
        if let virtualDisplay { installDisplayCleanup(virtualDisplay) }
        let width = argInt(args, "--width", 3840)
        let height = argInt(args, "--height", 2160)
        let port = UInt16(argInt(args, "--port", 7474))
        let seconds = Double(argInt(args, "--seconds", 0))
        let dump = argValue(args, "--dump", "")
        let codecName = argValue(args, "--codec", "prores")
        let codec: VideoCodec = codecName == "prores" ? .prores422 : .hevc
        let bindSpec = argValue(args, "--bind", "auto")
        let insecure = args.contains("--insecure")
        var authKey = resolveAuthKey(args)
        if authKey == nil && !insecure {
            // Fresh install: nobody has a key yet, and copying one around is not
            // an option on machines without SSH. Generate it here and let the
            // operator read the password off the 被控端 panel.
            if PSK.ensureKey(args: args) != nil {
                // Not the password itself: this log ends up in a file on the
                // remote machine (the app redirects helper output into
                // ~/Library/Logs/BoltKVM.log). The panel shows it on demand.
                log("auth: generated a new connection password (saved to ~/.boltkvm-key; the 被控端 panel shows it)")
                // Re-resolve through the normal path so the generated password gets
                // the same stretching a client will apply to what the user types.
                authKey = resolveAuthKey(args)
            } else {
                log("refusing to start: no pre-shared key and cannot create ~/.boltkvm-key; pass --key, set $BOLTKVM_KEY, or use --insecure")
                exit(2)
            }
        }
        if insecure { log("WARNING: --insecure — anyone who can reach this port controls the machine") }
        if let authKey { log("auth: key fingerprint \(PSK.fingerprint(authKey))") }
        if let virtualDisplay {
            // Losing the display means capture is meaningless; exit and let the
            // supervisor recreate the process (and with it, the display).
            virtualDisplay.onLost = {
                log("virtual display: removed by the system; exiting so the supervisor can recreate it")
                exit(3)
            }
        }
        do {
            // The virtual display is already on screen at this point, and it is
            // owned by this process. Exiting because the port cannot be bound
            // (no Thunderbolt bridge on a headless Mac reached through UU/ARD,
            // or the previous helper still holding the port) destroyed that
            // display every few seconds: the supervisor restarted us, we made a
            // new display, failed to bind and died again. On a remote console
            // that reads as the desktop flipping between two resolutions.
            // Keep the display and wait for a usable network instead.
            var waitedForNetwork = false
            var listener: TCPListener
            while true {
                do {
                    listener = try TCPListener(port: port, bind: bindSpec)
                    if waitedForNetwork { log("network: network is available again; starting to listen") }
                    break
                } catch {
                    guard isTransientBindError(error) else { throw error }
                    if !waitedForNetwork {
                        let reason = (error as? POSIXError)?.code == .EADDRINUSE
                            ? "port \(port) is still in use"
                            : error.localizedDescription
                        log("network: \(reason); keeping the virtual display up and retrying every 2 s")
                        log("network: waiting for a usable network (virtual display stays up)")
                        waitedForNetwork = true
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            let deadline: UInt64? = seconds > 0
                ? DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
                : nil
            log("listening on \(listener.label):\(port) (\(seconds > 0 ? "\(Int(seconds))s total" : "forever")), auth=\(authKey == nil ? "OFF" : "psk"); waiting for client")
            while true {
                if let d = deadline, DispatchTime.now().uptimeNanoseconds >= d { break }
                let conn = try await acceptAsync(listener)
                log("client connected")
                var requested: SessionConfig?
                if let key = authKey {
                    do {
                        requested = try authenticateServer(conn: conn, key: key)
                        log("auth ok")
                    } catch {
                        log("auth failed: \(error); closing")
                        conn.close()
                        // 8 characters from a 31-symbol alphabet is ~40 bits, so guessing is already out of
                        // reach; the pause just keeps a stuck client from spinning
                        // the CPU and slows anyone who tries anyway.
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                }
                let audio = args.contains("--audio")

                var captureW = width
                var captureH = height
                if let req = requested, let current = virtualDisplay,
                   current.logicalWidth != req.width || current.logicalHeight != req.height {
                    log("client requested \(req.width)x\(req.height) (quality \(req.quality)); recreating virtual display")
                    let previous = virtualDisplay
                    await MainActor.run { previous?.stop() }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let made = await MainActor.run {
                        BuiltinVirtualDisplay(name: "boltKVM-\(req.width)x\(req.height)",
                                              width: req.width, height: req.height, hiDPI: true)
                    }
                    if let made {
                        virtualDisplay = made
                        installDisplayCleanup(made)
                        made.onLost = {
                            log("virtual display: removed by the system; exiting so the supervisor can recreate it")
                            exit(3)
                        }
                        captureW = req.quality == 0 ? min(req.width, 3840) : req.width * 2
                        captureH = req.quality == 0
                            ? max(2, captureW * req.height / req.width)
                            : req.height * 2
                        let even = evenVideoSize(width: captureW, height: captureH)
                        captureW = even.width
                        captureH = even.height
                        log("virtual display recreated: logical \(req.width)x\(req.height), streaming \(captureW)x\(captureH)")
                        // Same reason as at startup: a fresh display without user
                        // activity is throttled to ~27 fps.
                        await MainActor.run { wakeDisplay() }
                        // Let WindowServer settle before ScreenCaptureKit looks
                        // for the new display, otherwise it enumerates none.
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                    } else {
                        log("recreating the virtual display failed; keeping \(current.logicalWidth)x\(current.logicalHeight)")
                    }
                }

                let desiredColor = requested?.color ?? .standard
                let server = Server(width: captureW, height: captureH, codec: codec, connection: conn,
                            dumpPath: dump.isEmpty ? nil : dump, audioEnabled: audio,
                            preferredDisplayID: argInt(args, "--display-id", 0) != 0
                                ? CGDirectDisplayID(argInt(args, "--display-id", 0))
                                : virtualDisplay?.displayID,
                            colorMode: desiredColor,
                            clipboardEnabled: !args.contains("--no-clipboard"),
                            muteLocalOutput: !args.contains("--no-local-mute"),
                            clipboardMaxItemBytes: clipboardMaxItemBytes(args),
                            clipboardMaxTransferBytes: clipboardMaxTransferBytes(args))
                do {
                    try await server.start()
                } catch {
                    log("session start failed: \(error)")
                    // start() may have created the clipboard timer or muted the
                    // output before the capture failed; unwind both.
                    await server.stop()
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
    public static func runInputProbe(_ args: [String]) async {
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

    public static func runDoctor(_ args: [String]) {
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

    nonisolated(unsafe) public static var patternTimer: Timer?
    nonisolated(unsafe) public static var patternActivity: NSObjectProtocol?

    /// Round-trips the session cipher: both directions, many packets, and the
    /// three failure modes that matter (tampered body, tampered header, wrong
    /// key). No network, no TCC — run it after touching the crypto code.
    /// Every display with the flags that decide whether capture can keep up:
    /// a sleeping or inactive display delivers frames only when content changes.
    public static func runDisplays() {
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

    public static func runCryptoTest() {
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

    public static func runSelftest() {
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
    public static func runPattern(_ args: [String]) async {
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
    public static func runClientRender(_ args: [String]) async {
        let host = argValue(args, "--host", "127.0.0.1")
        let port = UInt16(argInt(args, "--port", 7474))
        let requested = parseRequestSize(args)
        let seconds = Double(argInt(args, "--seconds", 20))
        let switchMode = args.contains("--switch-mode")
        let wantsInput = args.contains("--input")
        let reconnect = args.contains("--reconnect")
        let audioRecord = argValue(args, "--audio-record", "")
        let wantsAudio = args.contains("--audio") || !audioRecord.isEmpty
        let audio: AudioPlayer? = wantsAudio
            ? AudioPlayer(play: args.contains("--audio"), recordPath: audioRecord.isEmpty ? nil : audioRecord)
            : nil

        let clipboardEnabled = !args.contains("--no-clipboard")
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
                var authSentAt: Int64 = 0
                do {
                    let c = try tcpConnect(host: host, port: port)
                    conn = c
                    log("connected to \(host):\(port)")
                    try c.send(timeSyncRequest())
                    let decoder = VideoDecoder()
                    decoder.renderer = RenderSession.shared.renderer
                    lastDecoder = decoder
                    var inputStarted = false
                    var clipboardSync: ClipboardSync?
                    let pump = SessionPump(conn: c, decoder: decoder)
                    pump.onClipboard = { clipboardSync?.handleClipboard($0) }
                    pump.onFileTransfer = { clipboardSync?.handleFile($0) }
                    pump.onChallenge = { payload in
                        sawChallenge = true
                        challengeNonce = payload
                        authSentAt = Int64(Date().timeIntervalSince1970 * 1_000_000)
                        try respondToAuthChallenge(conn: c, nonce: payload)
                    }
                    pump.onAuthOk = { header, payload in
                        sawAuthOk = true
                        try enableClientEncryption(
                            conn: c, nonce: challengeNonce,
                            forwardSecrecy: authOkFlags(payload) & FLAG_SUPPORTS_KEY_EXCHANGE != 0)
                        log("auth ok")
                        installPauseOnRouteChange(audio, conn: c)
                        if clipboardEnabled {
                            let sync = ClipboardSync(conn: c, enabled: true,
                                                     maxItemBytes: clipboardMaxItemBytes(args),
                                                     maxTransferBytes: clipboardMaxTransferBytes(args))
                            sync.start()
                            clipboardSync = sync
                        }
                        if header.payloadLength >= 9, payload.first == 1, authSentAt > 0 {
                            let t2 = payload.readInt64BE(payload.startIndex + 1)
                            let t3 = Int64(Date().timeIntervalSince1970 * 1_000_000)
                            decoder.setClockOffset(t2 - (authSentAt + t3) / 2,
                                                   rttMs: Double(t3 - authSentAt) / 1000.0)
                        }
                        if header.payloadLength >= 1, payload.first == 1, let requested {
                            try? c.send(packet(type: .config, payload: requested.encode()))
                            log("sent config \(requested.width)x\(requested.height) quality=\(requested.quality)")
                        }
                        try? c.send(timeSyncRequest())
                    }
                    pump.onFormat = { _ in
                        if wantsInput && !inputStarted {
                            inputStarted = true
                            DispatchQueue.main.async {
                                RenderSession.shared.restartInput(conn: c)
                            }
                        }
                    }
                    pump.onAudio = { [audio] payload in audio?.enqueue(payload) }
                    pump.onWindow = { window in
                        packets += window.packets
                        frames += window.frames
                        winBytes += window.bytes
                        winFrames += window.frames
                        let beatNow = DispatchTime.now().uptimeNanoseconds
                        if beatNow - lastBeat >= 60_000_000_000 {
                            let secs = Double(beatNow - lastBeat) / 1e9
                            let mbps = secs > 0 ? Double(winBytes) * 8 / secs / 1e6 : 0
                            let kbFrame = winFrames > 0 ? Double(winBytes) / Double(winFrames) / 1024 : 0
                            let budget = Renderer.budgetMs
                            lastBeat = beatNow
                            log(String(format: "loop.win packets=%d frames=%d reconnects=%d mbps=%.1f kbFrame=%.0f budget=%.0fms",
                                       packets, frames, reconnects, mbps, kbFrame, budget))
                            winBytes = 0
                            winFrames = 0
                        }
                    }
                    try pump.run(deadline: DispatchTime(uptimeNanoseconds: deadline))
                    clipboardSync?.stop()
                    c.close()
                    break
                } catch {
                    if sawChallenge && !sawAuthOk {
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

    /// `--request-size 2560x1440` exercises the config packet from the CLI.
    static func parseRequestSize(_ args: [String]) -> SessionConfig? {
        let raw = argValue(args, "--request-size", "")
        let parts = raw.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let quality = UInt8(argInt(args, "--request-quality", 1))
        let color: ColorMode = argValue(args, "--color", "standard") == "wide" ? .wide : .standard
        return SessionConfig(width: parts[0], height: parts[1], quality: quality, color: color)
    }

    public static func runClient(_ args: [String]) async {
        let host = argValue(args, "--host", "127.0.0.1")
        let port = UInt16(argInt(args, "--port", 7474))
        let requested = parseRequestSize(args)
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
            let pump = SessionPump(conn: conn, decoder: decoder)
            var clipboardSync: ClipboardSync?
            pump.onClipboard = { clipboardSync?.handleClipboard($0) }
            pump.onFileTransfer = { clipboardSync?.handleFile($0) }
            var challengeNonce: Data?
            var authSentAt: Int64 = 0
            pump.onChallenge = { payload in
                challengeNonce = payload
                authSentAt = Int64(Date().timeIntervalSince1970 * 1_000_000)
                try respondToAuthChallenge(conn: conn, nonce: payload)
            }
            pump.onAuthOk = { header, payload in
                try enableClientEncryption(
                    conn: conn, nonce: challengeNonce,
                    forwardSecrecy: authOkFlags(payload) & FLAG_SUPPORTS_KEY_EXCHANGE != 0)
                log("auth ok")
                installPauseOnRouteChange(audio, conn: conn)
                if !args.contains("--no-clipboard") {
                    let sync = ClipboardSync(conn: conn, enabled: true,
                                             maxItemBytes: clipboardMaxItemBytes(args),
                                             maxTransferBytes: clipboardMaxTransferBytes(args))
                    sync.start()
                    clipboardSync = sync
                }
                if header.payloadLength >= 9, payload.first == 1, authSentAt > 0 {
                    let t2 = payload.readInt64BE(payload.startIndex + 1)
                    let t3 = Int64(Date().timeIntervalSince1970 * 1_000_000)
                    decoder.setClockOffset(t2 - (authSentAt + t3) / 2,
                                           rttMs: Double(t3 - authSentAt) / 1000.0)
                }
                if header.payloadLength >= 1, payload.first == 1, let requested {
                    try? conn.send(packet(type: .config, payload: requested.encode()))
                    log("sent config \(requested.width)x\(requested.height) quality=\(requested.quality)")
                }
                try? conn.send(timeSyncRequest())
            }
            pump.onAudio = { audio?.enqueue($0) }
            pump.onLongWindow = { packets, received in
                log("loop.win packets=\(packets) received=\(received)")
            }
            do {
                try pump.run(deadline: DispatchTime(uptimeNanoseconds: deadline))
            } catch {
                log("client read error: \(error)")
            }
            clipboardSync?.stop()
            audio?.finish()
            decoder.report()
            log("received frames=\(pump.frames) lastType=\(String(describing: pump.lastType))")
            conn.close()
            exit(0)
        } catch {
            log("client error: \(error)")
            exit(1)
        }
    }

    /// `usage()` lives with the other CLI helpers; re-export the one entry the
    /// dispatcher needs.
    public static func printUsage() -> Never { usage() }

    public static func runWatchdog(_ args: [String]) { Watchdog.run(args) }
}
