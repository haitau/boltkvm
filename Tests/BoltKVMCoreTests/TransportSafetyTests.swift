import XCTest
@testable import BoltKVMCore
import CryptoKit
import Darwin

/// Wire-level guarantees that are easy to break and expensive to notice in the
/// field: nonce order under concurrent senders, "encrypted means encrypted",
/// the payload cap, and idempotent close.
final class TransportSafetyTests: XCTestCase {
    private func makePair() -> (TCPConnection, TCPConnection) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (TCPConnection(fd: fds[0]), TCPConnection(fd: fds[1]))
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            guard let base = raw.baseAddress else { return }
            while off < raw.count {
                let n = Darwin.send(fd, base.advanced(by: off), raw.count - off, 0)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Frames are sealed and written under one lock, so the peer must be able to
    /// decrypt every frame in the order it was numbered — no matter how many
    /// threads call `send`.
    func testConcurrentSendersKeepNonceOrder() throws {
        let (sender, receiver) = makePair()
        let key = SymmetricKey(size: .bits256)
        sender.setSessionCiphers(send: SessionCipher(key: key), recv: nil)
        receiver.setSessionCiphers(send: nil, recv: SessionCipher(key: key))

        let threads = 6
        let perThread = 50
        let total = threads * perThread
        let bodySize = 4

        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var payloads = Set<Data>()
        nonisolated(unsafe) var readError: Error?

        DispatchQueue.global().async {
            for _ in 0..<total {
                do {
                    let (head, body) = try receiver.recvFrame()
                    if head.type != .input || body.count != bodySize {
                        readError = POSIXError(.EBADMSG)
                        break
                    }
                    payloads.insert(body)
                } catch {
                    readError = error
                    break
                }
            }
            finished.signal()
        }

        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                let n = t * perThread + i
                var body = Data(count: bodySize)
                body[0] = UInt8(n >> 24)
                body[1] = UInt8((n >> 16) & 0xff)
                body[2] = UInt8((n >> 8) & 0xff)
                body[3] = UInt8(n & 0xff)
                try? sender.send(packet(type: .input, flags: 0, ptsMicros: 0, payload: body))
            }
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success,
                       "reader timed out; concurrent sends deadlocked or reordered")
        XCTAssertNil(readError, "reader failed: \(String(describing: readError))")
        XCTAssertEqual(payloads.count, total, "duplicate payloads: a nonce was reused")
        sender.close()
        receiver.close()
    }

    /// After the ciphers are installed, a plaintext frame is a protocol error:
    /// otherwise the flag byte (which is not MACed) decides whether a frame is
    /// authenticated, and anyone on the link can inject input or video.
    func testPlaintextFrameIsRejectedOnceEncrypted() throws {
        let (sender, receiver) = makePair()
        let key = SymmetricKey(size: .bits256)
        receiver.setSessionCiphers(send: nil, recv: SessionCipher(key: key))

        writeAll(sender.fd, packet(type: .input, flags: 0, ptsMicros: 0,
                                   payload: Data([5, 1, 0, 0])))
        XCTAssertThrowsError(try receiver.recvFrame()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EPROTO)
        }
        sender.close()
        receiver.close()
    }

    /// A 20-byte header claiming a huge body must fail before the allocation.
    func testOversizedPayloadIsRejected() throws {
        let (sender, receiver) = makePair()
        let header = PacketHeader(type: .frame, flags: 0, ptsMicros: 0,
                                  payloadLength: 0xFFFF_FFFF).encode()
        XCTAssertEqual(header.count, HEADER_SIZE)
        writeAll(sender.fd, header)
        XCTAssertThrowsError(try receiver.recvFrame()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EBADMSG)
        }
        sender.close()
        receiver.close()
    }

    /// A packet type this build does not know must be skipped, not treated as a
    /// protocol error: that is what lets a new peer add packet types without
    /// killing an older session.
    func testUnknownPacketTypeIsSkipped() throws {
        let (conn, peer) = makePair()
        let pump = SessionPump(conn: conn, decoder: VideoDecoder())
        var raw = Data()
        raw.appendUInt32BE(BKVM_MAGIC)
        raw.append(BKVM_VERSION)
        raw.append(200)          // unknown type
        raw.append(0)            // flags
        raw.append(0)
        raw.appendUInt32BE(3)    // payload length
        raw.appendInt64BE(0)
        raw.append(contentsOf: [1, 2, 3])
        writeAll(peer.fd, raw)
        peer.close()

        XCTAssertThrowsError(try pump.run())  // EOF ends the loop
        XCTAssertEqual(pump.packets, 1)
        XCTAssertEqual(pump.lastType, .unknown)
        conn.close()
    }

    /// The input payload layout is a wire format: offsets, endianness and the
    /// 48-byte size are shared with the server's injector. Round-trip plus a
    /// byte-level check so a field reorder cannot slip through.
    func testInputEventLayoutRoundTrips() throws {
        let ev = InputEvent(type: .rightMouseDown, keyCode: 0x1234, flags: 0x100000,
                            x: 0.25, y: 0.75, button: 1,
                            scrollX: 2.5, scrollY: -3.5, phase: 2, momentum: 1, isRepeat: true)
        let d = ev.encode()
        XCTAssertEqual(d.count, 48)
        XCTAssertEqual(d[0], InputEventType.rightMouseDown.rawValue)
        XCTAssertEqual(d[1], 0x12)  // big-endian UInt16 keyCode
        XCTAssertEqual(d[2], 0x34)
        // big-endian UInt64 flags: 0x100000 = 1 << 20 -> the 0x10 lands at byte 8
        XCTAssertEqual(Array(d[3..<8]), [0, 0, 0, 0, 0])
        XCTAssertEqual(d[8], 0x10)
        XCTAssertEqual(d[27], 1)    // button
        XCTAssertEqual(d[44], 2)    // phase
        XCTAssertEqual(d[45], 1)    // momentum
        XCTAssertEqual(d[46], 1)    // isRepeat
        let back = try XCTUnwrap(InputEvent.decode(d))
        XCTAssertEqual(back.type, ev.type)
        XCTAssertEqual(back.keyCode, ev.keyCode)
        XCTAssertEqual(back.flags, ev.flags)
        XCTAssertEqual(back.x, ev.x)
        XCTAssertEqual(back.y, ev.y)
        XCTAssertEqual(back.button, ev.button)
        XCTAssertEqual(back.scrollX, ev.scrollX)
        XCTAssertEqual(back.scrollY, ev.scrollY)
        XCTAssertEqual(back.phase, ev.phase)
        XCTAssertEqual(back.momentum, ev.momentum)
        XCTAssertEqual(back.isRepeat, ev.isRepeat)
        XCTAssertNil(InputEvent.decode(d.prefix(47)))
    }

    func testCloseIsIdempotent() {
        let (conn, peer) = makePair()
        conn.close()
        conn.close()
        peer.close()
    }
}
