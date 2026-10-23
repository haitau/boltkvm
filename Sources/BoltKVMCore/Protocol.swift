import Foundation
import Darwin
import CryptoKit
import Security

// MARK: - Wire format
//
// Every message is a 20-byte header followed by a payload:
//   magic(4) version(1) type(1) flags(1) reserved(1) payloadLength(4) ptsMicros(8)
// Multi-byte integers are big-endian.
//
// type=1 format: width(4) height(4) paramCount(1) [paramLen(2) paramBytes]...
// type=2 frame:  raw HEVC AVCC stream (length-prefixed NAL units), no extra header
//
// flags bit0: keyframe (frame packets only)

let BKVM_MAGIC: UInt32 = 0x424B_564D // "BKVM"
let BKVM_VERSION: UInt8 = 1
let HEADER_SIZE = 20

enum PacketType: UInt8 {
    case format = 1
    case frame = 2
    case heartbeat = 3
    case timeSync = 4
    case input = 5
    case authChallenge = 6
    case authResponse = 7
    case authOk = 8
    /// Opt-in only (server `--audio`): raw PCM, 48 kHz, 2 ch, int16 LE,
    /// interleaved. Without the flag no such packet is ever produced.
    case audio = 9
    /// Remote control of system UI that no keyboard event can trigger: the
    /// server performs the action natively (see `RemoteAction`).
    case command = 10
    /// First packet after `authOk`: what the client wants streamed. Sent by new
    /// clients only, so old servers simply ignore an unknown type.
    case config = 11
}

/// What a client asks the server to stream: a logical size plus how sharp.
///
/// The server may refuse (no virtual display to recreate, or the display is
/// external); it then keeps its current size and the client learns the truth
/// from the `format` packet.
struct SessionConfig {
    var width: Int
    var height: Int
    /// 0 = standard (cap the stream at 3840 wide), 1 = pixel (2x logical).
    var quality: UInt8

    static let payloadSize = 8

    func encode() -> Data {
        var data = Data(count: SessionConfig.payloadSize)
        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            base.storeBytes(of: UInt16(clamping: width).bigEndian, toByteOffset: 0, as: UInt16.self)
            base.storeBytes(of: UInt16(clamping: height).bigEndian, toByteOffset: 2, as: UInt16.self)
            base.storeBytes(of: quality, toByteOffset: 4, as: UInt8.self)
            base.storeBytes(of: UInt8(0), toByteOffset: 5, as: UInt8.self)
            base.storeBytes(of: UInt16(0).bigEndian, toByteOffset: 6, as: UInt16.self)
        }
        return data
    }

    static func decode(_ data: Data) -> SessionConfig? {
        guard data.count >= SessionConfig.payloadSize else { return nil }
        return data.withUnsafeBytes { raw -> SessionConfig? in
            let base = raw.baseAddress!
            let width = Int(UInt16(bigEndian: base.load(fromByteOffset: 0, as: UInt16.self)))
            let height = Int(UInt16(bigEndian: base.load(fromByteOffset: 2, as: UInt16.self)))
            let quality = base.load(fromByteOffset: 4, as: UInt8.self)
            guard (320...7680).contains(width), (240...4320).contains(height) else { return nil }
            return SessionConfig(width: width, height: height, quality: quality)
        }
    }
}

/// Actions the client asks the *server* to perform. These are deliberately not
/// synthesised keystrokes: macOS ignores synthetic events for system hotkeys
/// (Mission Control, Show Desktop, App Exposé), which is why they need a path of
/// their own.
enum RemoteAction: UInt8 {
    case missionControl = 1
    case showDesktop = 2
    case appWindows = 3
    case spaceLeft = 4
    case spaceRight = 5
}

struct PacketHeader {
    var type: PacketType
    var flags: UInt8
    var ptsMicros: Int64
    var payloadLength: UInt32

    func encode() -> Data {
        var d = Data(capacity: HEADER_SIZE)
        d.appendUInt32BE(BKVM_MAGIC)
        d.append(BKVM_VERSION)
        d.append(type.rawValue)
        d.append(flags)
        d.append(0)
        d.appendUInt32BE(payloadLength)
        d.appendInt64BE(ptsMicros)
        return d
    }

    static func decode(_ d: Data) -> PacketHeader? {
        guard d.count >= HEADER_SIZE else { return nil }
        let base = d.startIndex
        let magic = d.readUInt32BE(base)
        guard magic == BKVM_MAGIC, d[base + 4] == BKVM_VERSION else { return nil }
        guard let type = PacketType(rawValue: d[base + 5]) else { return nil }
        let flags = d[base + 6]
        let len = d.readUInt32BE(base + 8)
        let pts = d.readInt64BE(base + 12)
        return PacketHeader(type: type, flags: flags, ptsMicros: pts, payloadLength: len)
    }
}

enum VideoCodec: UInt32 {
    case hevc = 1
    case prores422 = 2
}

struct StreamFormat {
    var width: Int
    var height: Int
    var codec: VideoCodec
    var parameterSets: [Data]

    func encode() -> Data {
        var d = Data()
        d.appendUInt32BE(UInt32(width))
        d.appendUInt32BE(UInt32(height))
        d.appendUInt32BE(codec.rawValue)
        d.append(UInt8(parameterSets.count))
        for ps in parameterSets {
            d.appendUInt16BE(UInt16(ps.count))
            d.append(ps)
        }
        return d
    }

    static func decode(_ d: Data) -> StreamFormat? {
        guard d.count >= 13 else { return nil }
        let base = d.startIndex
        let width = Int(d.readUInt32BE(base))
        let height = Int(d.readUInt32BE(base + 4))
        guard let codec = VideoCodec(rawValue: d.readUInt32BE(base + 8)) else { return nil }
        let n = Int(d[base + 12])
        var off = base + 13
        var ps: [Data] = []
        for _ in 0..<n {
            guard off + 2 <= d.endIndex else { return nil }
            let len = Int(d.readUInt16BE(off)); off += 2
            guard off + len <= d.endIndex else { return nil }
            ps.append(d.subdata(in: off..<(off + len)))
            off += len
        }
        return StreamFormat(width: width, height: height, codec: codec, parameterSets: ps)
    }
}

enum InputEventType: UInt8 {
    case keyDown = 1
    case keyUp = 2
    case flagsChanged = 3
    case mouseMoved = 4
    case leftMouseDown = 5
    case leftMouseUp = 6
    case rightMouseDown = 7
    case rightMouseUp = 8
    case otherMouseDown = 9
    case otherMouseUp = 10
    case leftMouseDragged = 11
    case rightMouseDragged = 12
    case otherMouseDragged = 13
    case scroll = 14
}

struct InputEvent {
    var type: InputEventType
    var keyCode: UInt16 = 0
    var flags: UInt64 = 0
    var x: Double = 0        // normalized 0...1 in the client content
    var y: Double = 0
    var button: UInt8 = 0
    var scrollX: Double = 0
    var scrollY: Double = 0
    var phase: UInt8 = 0
    var momentum: UInt8 = 0
    var isRepeat: Bool = false

    func encode() -> Data {
        var d = Data(capacity: 48)
        d.append(type.rawValue)
        d.appendUInt16BE(keyCode)
        d.appendUInt64BE(flags)
        d.appendDoubleBE(x)
        d.appendDoubleBE(y)
        d.append(button)
        d.appendDoubleBE(scrollX)
        d.appendDoubleBE(scrollY)
        d.append(phase)
        d.append(momentum)
        d.append(isRepeat ? 1 : 0)
        d.append(0) // pad to 48
        return d
    }

    static func decode(_ d: Data) -> InputEvent? {
        guard d.count >= 48, let type = InputEventType(rawValue: d[d.startIndex]) else { return nil }
        let b = d.startIndex
        return InputEvent(
            type: type,
            keyCode: d.readUInt16BE(b + 1),
            flags: d.readUInt64BE(b + 3),
            x: d.readDoubleBE(b + 11),
            y: d.readDoubleBE(b + 19),
            button: d[b + 27],
            scrollX: d.readDoubleBE(b + 28),
            scrollY: d.readDoubleBE(b + 36),
            phase: d[b + 44],
            momentum: d[b + 45],
            isRepeat: d[b + 46] != 0
        )
    }
}

extension Data {
    mutating func appendUInt16BE(_ v: UInt16) {
        var b = v.bigEndian
        Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) }
    }
    mutating func appendUInt32BE(_ v: UInt32) {
        var b = v.bigEndian
        Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) }
    }
    mutating func appendInt64BE(_ v: Int64) {
        var b = v.bigEndian
        Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) }
    }
    mutating func appendUInt64BE(_ v: UInt64) {
        var b = v.bigEndian
        Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) }
    }
    mutating func appendDoubleBE(_ v: Double) {
        appendUInt64BE(v.bitPattern)
    }
    func readUInt64BE(_ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for j in 0..<8 { v = (v << 8) | UInt64(self[i + j]) }
        return v
    }
    func readDoubleBE(_ i: Int) -> Double {
        Double(bitPattern: readUInt64BE(i))
    }
    func readUInt32BE(_ i: Int) -> UInt32 {
        let b = self[i..<(i + 4)]
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    func readUInt16BE(_ i: Int) -> UInt16 {
        let b = self[i..<(i + 2)]
        return b.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }
    func readInt64BE(_ i: Int) -> Int64 {
        var v: UInt64 = 0
        for j in 0..<8 { v = (v << 8) | UInt64(self[i + j]) }
        return Int64(bitPattern: v)
    }
}

// MARK: - Auth
//
// The server listens on the Thunderbolt bridge only by default, and unless it is
// started with --insecure it also requires a pre-shared key: it sends a 32-byte
// nonce and expects HMAC-SHA256(key, nonce) back.
//
// Key resolution order: --key, $BOLTKVM_KEY, ~/.boltkvm-key (first non-empty
// line). A 64-char hex string is decoded as raw bytes, anything else is hashed
// as UTF-8 so a passphrase works too.

func resolveAuthKey(_ args: [String]) -> Data? {
    var candidates: [String] = []
    let flag = argValue(args, "--key", "")
    if !flag.isEmpty { candidates.append(flag) }
    if let env = ProcessInfo.processInfo.environment["BOLTKVM_KEY"], !env.isEmpty { candidates.append(env) }
    let path = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/.boltkvm-key"
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        let line = (text.split(separator: "\n").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { candidates.append(line) }
    }
    guard let raw = candidates.first else { return nil }
    // A generated connection password (8 chars, no separators) is stretched: see
    // PSK.stretch for why. The normalisation also makes `K7M3-P9QX` == `k7m3p9qx`.
    if PSK.isGeneratedPassword(raw) {
        return PSK.stretch(raw)
    }
    if raw.count == 64, raw.allSatisfy({ $0.isHexDigit }) {
        var out = Data(capacity: 32)
        var i = raw.startIndex
        while i < raw.endIndex {
            let j = raw.index(i, offsetBy: 2)
            guard let b = UInt8(raw[i..<j], radix: 16) else { return Data(raw.utf8) }
            out.append(b)
            i = j
        }
        return out
    }
    return Data(raw.utf8)
}

func authMAC(key: Data, nonce: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: key)))
}

func authMACMatches(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

func randomNonce(_ count: Int = 32) -> Data {
    var d = Data(count: count)
    d.withUnsafeMutableBytes { ptr in
        if let base = ptr.baseAddress { _ = SecRandomCopyBytes(kSecRandomDefault, count, base) }
    }
    return d
}

// MARK: - TCP

/// Set in PacketHeader.flags when the payload is ChaCha20-Poly1305 sealed.
let FLAG_ENCRYPTED: UInt8 = 0x2

/// Session keys derived from the same PSK the HMAC handshake used, salted with
/// the server's challenge nonce — no extra round trip, and a fresh key per
/// connection because the nonce is random.
func deriveSessionKeys(psk: Data, nonce: Data) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
    let ikm = SymmetricKey(data: psk)
    let c2s = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: nonce,
                                     info: Data("boltkvm c2s".utf8), outputByteCount: 32)
    let s2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: nonce,
                                     info: Data("boltkvm s2c".utf8), outputByteCount: 32)
    return (c2s, s2c)
}

/// One direction of the encrypted stream. The header stays clear (it carries the
/// framing) but is authenticated as AAD, so type/length tampering is rejected.
/// Nonce is a 64-bit counter in the last 8 bytes; TCP is ordered, so both ends
/// stay in step without a replay window.
final class SessionCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    private func nextNonce() -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var c = counter.bigEndian
        withUnsafeBytes(of: &c) { raw in
            for i in 0..<8 { bytes[4 + i] = raw[i] }
        }
        counter &+= 1
        return try! ChaChaPoly.Nonce(data: Data(bytes))
    }

    func seal(_ frame: Data) -> Data {
        guard frame.count >= HEADER_SIZE else { return frame }
        var header = Data(frame.prefix(HEADER_SIZE))
        let body = Data(frame.dropFirst(HEADER_SIZE))
        header[6] |= FLAG_ENCRYPTED
        let newLength = UInt32(body.count + 16)
        header.replaceSubrange(8..<12, with: withUnsafeBytes(of: newLength.bigEndian) { Data($0) })
        let sealed = try! ChaChaPoly.seal(body, using: key, nonce: nextNonce(), authenticating: header)
        var out = header
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    func open(header: Data, body: Data) throws -> Data {
        guard body.count >= 16 else { throw POSIXError(.EBADMSG) }
        let ct = Data(body.dropLast(16))
        let tag = Data(body.suffix(16))
        let box = try ChaChaPoly.SealedBox(nonce: nextNonce(), ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: key, authenticating: header)
    }
}

final class TCPConnection {
    let fd: Int32
    private let sendLock = NSLock()
    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Nil until the handshake completes; both ends install them at the same
    /// protocol point (right after authOk) so the nonce counters stay aligned.
    var outCipher: SessionCipher?
    var inCipher: SessionCipher?

    func send(_ data: Data) throws {
        let wire = outCipher.map { $0.seal(data) } ?? data
        sendLock.lock()
        defer { sendLock.unlock() }
        try wire.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n > 0 { sent += n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func recvExact(_ count: Int) throws -> Data {
        var out = Data(count: count)
        var got = 0
        while got < count {
            let n: Int = out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(fd, base.advanced(by: got), count - got, 0)
            }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            got += n
        }
        return out
    }

    /// Reads one frame and decrypts it when the encrypted flag is set. Used by
    /// everything that runs after the handshake.
    func recvFrame() throws -> (PacketHeader, Data) {
        let hd = try recvExact(HEADER_SIZE)
        guard let head = PacketHeader.decode(hd) else { throw POSIXError(.EBADMSG) }
        let body = try recvExact(Int(head.payloadLength))
        if head.flags & FLAG_ENCRYPTED != 0 {
            guard let cipher = inCipher else { throw POSIXError(.EPROTO) }
            return (head, try cipher.open(header: hd, body: body))
        }
        return (head, body)
    }

    func setRecvTimeout(_ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() { Darwin.close(fd) }
}

struct BindTarget {
    let addr: in_addr
    let label: String
}

func ipv4String(_ a: in_addr) -> String {
    var x = a
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &x, &buf, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buf)
}

/// "auto" picks the first address on a Thunderbolt bridge (`bridge*`), so the
/// server is not reachable from Wi-Fi by default. Pass an explicit IPv4 address
/// to override, e.g. `--bind 127.0.0.1` for same-host tests.
func resolveBindAddress(_ spec: String) throws -> BindTarget {
    if spec == "auto" {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let head = ifap else {
            throw NSError(domain: "boltkvm", code: 2001,
                          userInfo: [NSLocalizedDescriptionKey: "getifaddrs failed; pass --bind <ipv4>"])
        }
        defer { freeifaddrs(ifap) }
        var cur: UnsafeMutablePointer<ifaddrs>? = head
        while let c = cur {
            let name = String(cString: c.pointee.ifa_name)
            if name.hasPrefix("bridge"), let sa = c.pointee.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET) {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                return BindTarget(addr: a, label: "\(name) \(ipv4String(a))")
            }
            cur = c.pointee.ifa_next
        }
        throw NSError(domain: "boltkvm", code: 2002, userInfo: [NSLocalizedDescriptionKey:
            "no Thunderbolt bridge address found; pass --bind 127.0.0.1 (loopback test) or --bind 0.0.0.0 (all interfaces)"])
    }
    var a = in_addr()
    guard inet_pton(AF_INET, spec, &a) == 1 else {
        throw NSError(domain: "boltkvm", code: 2003,
                      userInfo: [NSLocalizedDescriptionKey: "invalid --bind address '\(spec)'"])
    }
    return BindTarget(addr: a, label: spec)
}

final class TCPListener {
    let fd: Int32
    let label: String
    init(port: UInt16, bind spec: String = "auto") throws {
        let target = try resolveBindAddress(spec)
        label = target.label
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = target.addr
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard listen(fd, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func accept() throws -> TCPConnection {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let cfd = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &len)
            }
        }
        guard cfd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return TCPConnection(fd: cfd)
    }

    func close() { Darwin.close(fd) }
}

// MARK: - small helpers

func packet(type: PacketType, flags: UInt8 = 0, ptsMicros: Int64 = 0, payload: Data) -> Data {
    let header = PacketHeader(type: type, flags: flags, ptsMicros: ptsMicros, payloadLength: UInt32(payload.count))
    var d = header.encode()
    d.append(payload)
    return d
}

func log(_ s: String) {
    // Plain write(2), not FileHandle: Foundation raises an Objective-C exception
    // (and the process aborts, leaving a "quit unexpectedly" crash report) when
    // the descriptor is closed. The helper logs one line exactly when its parent
    // dies and stderr may already be a broken pipe.
    var bytes = Array((s + "\n").utf8)
    bytes.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        var offset = 0
        while offset < buf.count {
            let n = write(STDERR_FILENO, base.advanced(by: offset), buf.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

func tcpConnect(host: String, port: UInt16, timeoutSeconds: Int = 5) throws -> TCPConnection {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    let gai = getaddrinfo(host, String(port), &hints, &info)
    guard gai == 0, let first = info else {
        throw POSIXError(.EHOSTUNREACH)
    }
    defer { freeaddrinfo(info) }
    var lastErr: Int32 = ECONNREFUSED
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if fd >= 0 {
            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // The server sends a 1s heartbeat even when the desktop is static,
            // so a 10s receive timeout only trips on a real network failure.
            var recvTV = timeval(tv_sec: max(10, timeoutSeconds), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTV, socklen_t(MemoryLayout<timeval>.size))
            if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                return TCPConnection(fd: fd)
            }
            lastErr = errno
            Darwin.close(fd)
        }
        p = ai.pointee.ai_next
    }
    throw POSIXError(POSIXErrorCode(rawValue: lastErr) ?? .ECONNREFUSED)
}
