import Foundation
import CoreMedia
import CoreVideo
import Darwin
import AppKit

func usage() -> Never {
    print("""
    boltkvm — M1 alpha-prime spike

    server:
      boltkvm server [--width 3840] [--height 2160] [--port 7474] [--seconds 20]

    client:
      boltkvm client [--host <mini>] [--port 7474] [--seconds 20]

    utilities:
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
    decoder.setClockOffset(offset)
    log("time sync rtt=\(Double(t3 - t1) / 1000.0)ms server-local offset=\(Double(offset) / 1000.0)ms")
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
            log("listening on :\(port); waiting for client")
            let conn = try await acceptAsync(listener)
            log("client connected")
            let server = Server(width: width, height: height, codec: codec, connection: conn, dumpPath: dump.isEmpty ? nil : dump)
            try await server.start()
            if seconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await server.stop()
                server.reportLine()
                conn.close()
                listener.close()
                exit(0)
            } else {
                while true {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    server.reportLine()
                }
            }
        } catch {
            log("server error: \(error)")
            exit(1)
        }
    }

    nonisolated(unsafe) static var patternTimer: Timer?

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

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = RenderSession.shared
        RenderSession.shared.start(switchMode: switchMode)

        let decoder = VideoDecoder()
        decoder.renderer = RenderSession.shared.renderer

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let conn = try tcpConnect(host: host, port: port)
                log("connected to \(host):\(port)")
                try conn.send(timeSyncRequest())
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let hd = try conn.recvExact(HEADER_SIZE)
                    guard let header = PacketHeader.decode(hd) else { throw POSIXError(.EBADMSG) }
                    let payload = try conn.recvExact(Int(header.payloadLength))
                    if header.type == .format, let f = StreamFormat.decode(payload) {
                        try decoder.configure(f)
                    } else if header.type == .frame {
                        decoder.decode(payload, ptsMicros: header.ptsMicros)
                    } else if header.type == .timeSync {
                        handleTimeSync(header, payload, decoder: decoder)
                    }
                }
                sleep(1)
                decoder.report()
                conn.close()
            } catch {
                log("client render error: \(error)")
            }
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
