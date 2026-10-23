import XCTest
@testable import BoltKVMCore
import Darwin

/// The shared client loop: packet dispatch, counters, and how it ends. These
/// tests run it over a socketpair so they need no network and no display.
final class SessionPumpTests: XCTestCase {
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

    private func makePair() -> (TCPConnection, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (TCPConnection(fd: fds[0]), fds[1])
    }

    func testCountsFramesAndCallsAudioUntilPeerCloses() throws {
        let (conn, peer) = makePair()
        let pump = SessionPump(conn: conn, decoder: VideoDecoder())
        var audioPackets = 0
        pump.onAudio = { _ in audioPackets += 1 }
        for i in 0..<3 {
            writeAll(peer, packet(type: .frame, flags: 0, ptsMicros: Int64(i),
                                  payload: Data([UInt8(i)])))
        }
        writeAll(peer, packet(type: .audio, ptsMicros: 0, payload: Data([1, 2, 3])))
        close(peer)

        XCTAssertThrowsError(try pump.run())
        XCTAssertEqual(pump.frames, 3)
        XCTAssertEqual(pump.packets, 4)
        XCTAssertEqual(audioPackets, 1)
        XCTAssertEqual(pump.lastType, .audio)
    }

    func testChallengeAndAuthOkCallbacksFire() throws {
        let (conn, peer) = makePair()
        let pump = SessionPump(conn: conn, decoder: VideoDecoder())
        var nonce: Data?
        var clock: Int64?
        pump.onChallenge = { nonce = $0 }
        pump.onAuthOk = { _, payload in clock = payload.readInt64BE(payload.startIndex + 1) }
        writeAll(peer, packet(type: .authChallenge, flags: 0, ptsMicros: 0,
                              payload: Data(repeating: 7, count: 32)))
        var ok = Data([1])
        ok.appendInt64BE(123_456_789)
        ok.append(FLAG_SUPPORTS_KEY_EXCHANGE)
        writeAll(peer, packet(type: .authOk, flags: 0, ptsMicros: 0, payload: ok))
        close(peer)

        XCTAssertThrowsError(try pump.run())
        XCTAssertEqual(nonce?.count, 32)
        XCTAssertEqual(clock, 123_456_789)
    }

    func testDeadlineStopsBeforeReading() throws {
        let (conn, peer) = makePair()
        let pump = SessionPump(conn: conn, decoder: VideoDecoder())
        writeAll(peer, packet(type: .heartbeat, flags: 0, ptsMicros: 0, payload: Data()))
        XCTAssertNoThrow(try pump.run(deadline: .now()))
        XCTAssertEqual(pump.packets, 0)
        close(peer)
    }

    /// A callback that throws (auth response send failure) must end the loop
    /// instead of being swallowed.
    func testThrowingCallbackPropagates() throws {
        let (conn, peer) = makePair()
        let pump = SessionPump(conn: conn, decoder: VideoDecoder())
        pump.onChallenge = { _ in throw POSIXError(.EIO) }
        writeAll(peer, packet(type: .authChallenge, flags: 0, ptsMicros: 0,
                              payload: Data(repeating: 1, count: 32)))
        close(peer)
        XCTAssertThrowsError(try pump.run()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
        XCTAssertEqual(pump.lastType, .authChallenge)
    }
}
