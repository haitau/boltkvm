import XCTest
@testable import BoltKVMCore
import Darwin

/// The server owns the virtual display, so deciding "retry" instead of "exit"
/// on a bind failure is what keeps the desktop from disappearing and coming back
/// on a headless Mac. Missing bridge, held port and a vanished address are all
/// transient; a bad `--bind` value is not.
final class BindRetryTests: XCTestCase {
    private func boltkvmError(_ code: Int) -> NSError {
        NSError(domain: "boltkvm", code: code,
                userInfo: [NSLocalizedDescriptionKey: "test error \(code)"])
    }

    func testMissingBridgeIsTransient() {
        XCTAssertTrue(isTransientBindError(boltkvmError(2002)))
    }

    func testPortStillHeldIsTransient() {
        XCTAssertTrue(isTransientBindError(POSIXError(.EADDRINUSE)))
    }

    func testAddressDisappearedIsTransient() {
        XCTAssertTrue(isTransientBindError(POSIXError(.EADDRNOTAVAIL)))
    }

    func testInvalidAddressIsFatal() {
        XCTAssertFalse(isTransientBindError(boltkvmError(2003)))
    }

    func testPermissionDeniedIsFatal() {
        XCTAssertFalse(isTransientBindError(POSIXError(.EACCES)))
    }
}
