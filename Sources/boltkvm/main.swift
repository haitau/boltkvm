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

    client:
      boltkvm client [--host <mini>] [--port 7474] [--seconds 20] [--render] [--switch-mode] [--input] [--reconnect]

    utilities:
      boltkvm doctor [--role server|client]
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
            await runServer(args)
        case "doctor":
            runDoctor(args)
        case "watchdog":
            Watchdog.run(args)
        case "selftest":
            runSelftest()
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

    static func runServer(_ args: [String]) async {
        let width = argInt(args, "--width", 3840)
        let height = argInt(args, "--height", 2160)
        let port = UInt16(argInt(args, "--port", 7474))
        let seconds = Double(argInt(args, "--seconds", 0))
        let dump = argValue(args, "--dump", "")
        let codecName = argValue(args, "--codec", "prores")
        let codec: VideoCodec = codecName == "prores" ? .prores422 : .hevc
        do {
            let listener = try TCPListener(port: port)
            let deadline: UInt64? = seconds > 0
                ? DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
                : nil
            log("listening on :\(port) (\(seconds > 0 ? "\(Int(seconds))s total" : "forever")); waiting for client")
            while true {
                if let d = deadline, DispatchTime.now().uptimeNanoseconds >= d { break }
                let conn = try await acceptAsync(listener)
                log("client connected")
                let server = Server(width: width, height: height, codec: codec, connection: conn, dumpPath: dump.isEmpty ? nil : dump)
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

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = RenderSession.shared
        RenderSession.shared.start(switchMode: switchMode)

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            var lastDecoder: VideoDecoder?
            while DispatchTime.now().uptimeNanoseconds < deadline {
                var conn: TCPConnection?
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
                        let hd = try c.recvExact(HEADER_SIZE)
                        guard let header = PacketHeader.decode(hd) else { throw POSIXError(.EBADMSG) }
                        let payload = try c.recvExact(Int(header.payloadLength))
                        if header.type == .format, let f = StreamFormat.decode(payload) {
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
                        }
                    }
                    c.close()
                    break
                } catch {
                    log("client render error: \(error)")
                    conn?.close()
                    DispatchQueue.main.async { RenderSession.shared.stopInput() }
                    if !reconnect { break }
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
            sleep(1)
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
        do {
            let conn = try tcpConnect(host: host, port: port)
            log("connected to \(host):\(port)")
            try conn.send(timeSyncRequest())
            let decoder = VideoDecoder()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
            var received = 0
            var lastHeader: PacketHeader?
            while DispatchTime.now().uptimeNanoseconds < deadline {
                do {
                    let hd = try conn.recvExact(HEADER_SIZE)
                    guard let header = PacketHeader.decode(hd) else { throw POSIXError(.EBADMSG) }
                    lastHeader = header
                    let payload = try conn.recvExact(Int(header.payloadLength))
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
                    case .input:
                        break
                    }
                } catch {
                    log("client read error: \(error)")
                    break
                }
            }
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
