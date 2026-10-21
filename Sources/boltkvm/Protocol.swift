import Foundation
import Darwin

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

// MARK: - TCP

final class TCPConnection {
    let fd: Int32
    private let sendLock = NSLock()
    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func send(_ data: Data) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
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

    func close() { Darwin.close(fd) }
}

final class TCPListener {
    let fd: Int32
    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
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
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
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
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
