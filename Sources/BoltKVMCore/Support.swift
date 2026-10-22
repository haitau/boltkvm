import Foundation
import IOKit.pwr_mgt
import CoreMedia
import CoreVideo
import Darwin
import AppKit
import ApplicationServices

/// A headless KVM must not let its virtual display fall asleep: once the system
/// marks the display ASLEEP, ScreenCaptureKit stops delivering frames and the
/// remote picture freezes (measured 2026-10-22: fps fell 45 -> 0 after the last
/// stimulus, display state `inactive ... ASLEEP`). The assertion is held for the
/// whole server lifetime and released when the process exits.
final class DisplaySleepAssertion {
    private var id: IOPMAssertionID = 0

    init(reason: String) {
        let created = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if created == kIOReturnSuccess {
            log("power: display sleep prevented (assertion \(id))")
        } else {
            log("power: could not create display assertion (0x\(String(created, radix: 16)))")
        }
    }

    func release() {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    deinit { release() }
}

/// When the app spawns us it hands over a stdin pipe and never writes to it, so
/// EOF means the app is gone (quit, crash, SIGKILL). Without this the helper
/// outlives the app, keeps the port bound and leaves the virtual display behind —
/// which then blocks the next launch from creating one with the same identity.
func exitWhenParentGoesAway() {
    guard ProcessInfo.processInfo.environment["BOLTKVM_EXIT_ON_STDIN_EOF"] == "1" else { return }
    // The parent may be gone by the time we write our last line.
    signal(SIGPIPE, SIG_IGN)
    Thread.detachNewThread {
        var byte: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &byte, 1)
            if n == 0 {
                log("parent closed stdin; exiting so the virtual display goes with us")
                exit(0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}

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
    enableClientEncryption(conn: conn, nonce: nonce, key: key)
}

func enableClientEncryption(conn: TCPConnection, nonce: Data, key: Data) {
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
    try respondToAuthChallenge(conn: conn, nonce: nonce, key: key)
}

/// Key-injecting variant for the app, which must not read CommandLine or exit.
func respondToAuthChallenge(conn: TCPConnection, nonce: Data, key: Data) throws {
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
