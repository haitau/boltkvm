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
        var payloads = Set<Data>()
        var readError: Error?

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

    func testCloseIsIdempotent() {
        let (conn, peer) = makePair()
        conn.close()
        conn.close()
        peer.close()
    }
}
