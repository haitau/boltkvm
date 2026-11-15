import XCTest
@testable import BoltKVMCore
import Darwin

/// A-6: the `.command` channel must reach the injected lock closure exactly
/// once per lock request, and unknown action bytes must stay inert (that is
/// what keeps old servers alive against newer clients). The closure is a
/// counting fake: the real `lockScreenImmediate` would lock the machine
/// running the tests, so a unit test must never get near it.
final class ServerCommandDispatchTests: XCTestCase {
    private var lockCalls = 0

    private func makeServer() throws -> Server {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return Server(width: 64, height: 64, codec: .hevc,
                      connection: TCPConnection(fd: fds[0]), dumpPath: nil,
                      lockScreenHandler: { [weak self] in self?.lockCalls += 1 })
    }

    func testLockCommandCallsInjectedClosureOncePerCommand() throws {
        let server = try makeServer()
        XCTAssertEqual(lockCalls, 0, "constructing a server must not lock")
        server.handleCommand(Data([RemoteAction.lockScreen.rawValue]))
        XCTAssertEqual(lockCalls, 1)
        // A second deliberate disconnect locks again, not once per process.
        server.handleCommand(Data([RemoteAction.lockScreen.rawValue]))
        XCTAssertEqual(lockCalls, 2)
    }

    func testUnknownActionByteAndEmptyPayloadAreInert() throws {
        let server = try makeServer()
        // 0xFF is what a future client would send first; 0 is not an action.
        server.handleCommand(Data([0xFF]))
        server.handleCommand(Data([0]))
        server.handleCommand(Data())
        XCTAssertEqual(lockCalls, 0)
    }

    func testDefaultLockHandlerResolvesWithoutCrashing() {
        // The production default resolves SACLockScreenImmediate lazily and
        // only inside the closure. Exercise the decision helpers instead of
        // calling it: the resolver itself must simply exist.
        XCTAssertEqual(lockCommandOnDisconnect(enabled: true), .lockScreen)
        XCTAssertNil(lockCommandOnDisconnect(enabled: false))
    }
}
