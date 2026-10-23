import Foundation
import CryptoKit
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
    boltkvm — low-latency macOS KVM over Thunderbolt

    server:
      boltkvm server [--width 3840] [--height 2160] [--port 7474] [--seconds 0]
                     [--virtual-display builtin|external] [--virtual-display-size WxH]
                     [--bind auto|<ipv4>] [--codec prores|hevc] [--key <psk>|--insecure]
                     [--audio]   # 默认不传音频；加 --audio 才采集并转发

    client:
      boltkvm client [--host <mini>] [--port 7474] [--seconds 20] [--render] [--switch-mode]
                     [--input] [--reconnect] [--key <psk>] [--request-size WxH] [--request-quality 0|1]
                     [--audio] [--audio-record <path>]   # 播放 / 落盘被控端音频

    utilities:
      boltkvm keygen [--path <file>] [--force]   # 生成 ~/.boltkvm-key 并打印指纹
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
@discardableResult
func authenticateServer(conn: TCPConnection, key: Data,
                        timeoutSeconds: Int = 5) throws -> SessionConfig? {
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
            // Capability byte: 1 = this server understands the `config` packet.
            // Old clients ignore the payload; old servers send an empty one, so a
            // new client talking to them simply does not ask for a size.
            //
            // The server's clock rides along for the same reason: the first
            // timeSync round trip happens before any video is queued, so the
            // client gets a clean offset instead of measuring a full socket.
            // [1][clock 8][flags 1]: version-1 clients read the clock at offset 1
            // and ignore the trailing flag byte, so the layout stays compatible.
            var payload = Data([1])
            payload.appendInt64BE(Int64(Date().timeIntervalSince1970 * 1_000_000))
            payload.append(FLAG_SUPPORTS_KEY_EXCHANGE)
            try conn.send(packet(type: .authOk, ptsMicros: 0, payload: payload))
            // Auth ok is the last plaintext packet: everything after it is sealed.
            let keys = deriveSessionKeys(psk: key, nonce: nonce)
            conn.setSessionCiphers(send: SessionCipher(key: keys.s2c),
                                   recv: SessionCipher(key: keys.c2s))
            return try awaitClientUpgrade(conn: conn, key: key, nonce: nonce)
        }
    }
    throw POSIXError(.ETIMEDOUT)
}

/// After `authOk` the client may immediately start an X25519 exchange (new
/// clients do, old ones go straight to `config` or stay silent). Both paths are
/// handled here so the caller only sees the resulting session.
private func awaitClientUpgrade(conn: TCPConnection, key: Data, nonce: Data) throws -> SessionConfig? {
    // Same 2 s budget as the client's wait for the reply: if we gave up earlier
    // we would start the session while the client still expects an authExchange
    // reply, and that packet would arrive as garbage mid-stream.
    conn.setRecvTimeout(2)
    defer { conn.setRecvTimeout(0) }
    guard let (head, body) = try? conn.recvFrame() else { return nil }

    if head.type == .authExchange, body.count == 32 {
        if let upgraded = try? finishKeyExchange(conn: conn, key: key, nonce: nonce, peerPublic: body) {
            // The exchange consumed the first frame; the size request (if any)
            // is the next one.
            return upgraded ? conn.nextConfig() : nil
        }
        return nil
    }
    return head.type == .config ? SessionConfig.decode(body) : nil
}

private extension TCPConnection {
    /// Reads at most one config frame, then restores the timeout.
    func nextConfig() -> SessionConfig? {
        setRecvTimeout(1)
        defer { setRecvTimeout(0) }
        guard let (head, body) = try? recvFrame(), head.type == .config else { return nil }
        return SessionConfig.decode(body)
    }
}

/// Server half of the X25519 exchange: reply with our public key using the
/// PSK-derived cipher, then switch both directions to keys that also depend on
/// the shared secret.
private func finishKeyExchange(conn: TCPConnection, key: Data, nonce: Data,
                               peerPublic: Data) throws -> Bool {
    let pair = Curve25519.KeyAgreement.PrivateKey()
    let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
    let shared = try pair.sharedSecretFromKeyAgreement(with: peer)
    try conn.send(packet(type: .authExchange, ptsMicros: 0,
                         payload: Data(pair.publicKey.rawRepresentation)))
    installSessionKeys(conn: conn, psk: key, nonce: nonce,
                       extra: shared.withUnsafeBytes { Data($0) }, client: false)
    log("auth: forward secrecy on (X25519)")
    return true
}

private func installSessionKeys(conn: TCPConnection, psk: Data, nonce: Data, extra: Data,
                                client: Bool) {
    let keys = deriveSessionKeys(psk: psk, nonce: nonce, extra: extra)
    // Both roles install at the same protocol point, but each direction has its
    // own key: the client sends with c2s and reads with s2c, the server the other
    // way round. Swapping them makes the first re-keyed packet fail to decrypt.
    conn.setSessionCiphers(send: SessionCipher(key: client ? keys.c2s : keys.s2c),
                           recv: SessionCipher(key: client ? keys.s2c : keys.c2s))
}

/// Installs the session ciphers once the server confirms auth. Both sides set
/// them at the same point (right after authOk), which keeps the nonce counters
/// aligned in each direction.
func enableClientEncryption(conn: TCPConnection, nonce: Data?, forwardSecrecy: Bool = false) throws {
    guard let nonce, let key = resolveAuthKey(CommandLine.arguments) else { return }
    try enableClientEncryption(conn: conn, nonce: nonce, key: key, forwardSecrecy: forwardSecrecy)
}

/// `forwardSecrecy` comes from the authOk flags: only a server that advertises it
/// gets an `authExchange` packet, so a new client talking to an old server never
/// desynchronises that server's cipher counters.
func enableClientEncryption(conn: TCPConnection, nonce: Data, key: Data,
                            forwardSecrecy: Bool = false) throws {
    let keys = deriveSessionKeys(psk: key, nonce: nonce)
    conn.setSessionCiphers(send: SessionCipher(key: keys.c2s),
                           recv: SessionCipher(key: keys.s2c))
    guard forwardSecrecy else { return }

    let pair = Curve25519.KeyAgreement.PrivateKey()
    try conn.send(packet(type: .authExchange, ptsMicros: 0,
                         payload: Data(pair.publicKey.rawRepresentation)))
    conn.setRecvTimeout(2)
    // After the handshake the client expects a heartbeat every second and pings
    // every three; a ten second silence means the peer is gone. Without this the
    // reader can sit in `recv` forever after an unplug or sleep and the window
    // keeps claiming it is streaming.
    defer { conn.setRecvTimeout(TCPConnection.sessionRecvTimeout) }
    let (head, body) = try conn.recvFrame()
    guard head.type == .authExchange, body.count == 32 else { throw POSIXError(.EPROTO) }
    let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: body)
    let shared = try pair.sharedSecretFromKeyAgreement(with: peer)
    installSessionKeys(conn: conn, psk: key, nonce: nonce,
                       extra: shared.withUnsafeBytes { Data($0) }, client: true)
    log("auth: forward secrecy on (X25519)")
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
    log("auth: key fingerprint \(PSK.fingerprint(key))")
    let mac = authMAC(key: key, nonce: nonce)
    try conn.send(packet(type: .authResponse, ptsMicros: 0, payload: mac))
}

/// Capability flags from an `authOk` payload. Empty/9-byte payloads come from
/// servers that predate the flag byte and mean "no extras".
func authOkFlags(_ payload: Data) -> UInt8 {
    guard payload.count >= 10 else { return 0 }
    return payload[payload.startIndex + 9]
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
