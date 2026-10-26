import XCTest
import CoreGraphics
@testable import BoltKVMCore

/// What the event tap subscribes to decides which input ever reaches the remote
/// side, and a missing bit fails silently — that kind of input simply never
/// arrives. Pinning the mask here makes the loss loud in CI instead.
final class InputCaptureMaskTests: XCTestCase {
    func testMaskMatchesTheAuditedEventSet() {
        // keyDown(10), keyUp(11), flagsChanged(12),
        // mouseMoved(5), left/right/other down/up/dragged(1-7, 25-27),
        // scrollWheel(22) → 0x0E401CFE.
        //
        // The mask is the fold of `InputCapture.capturedEventTypes`, so this
        // number is the audited copy of that list. Update it (and the comment)
        // whenever the forwarded input kinds change on purpose.
        XCTAssertEqual(InputCapture.eventMask, 0x0E40_1CFE)
    }

    func testNoEventTypeIsSubscribedTwice() {
        // A duplicate would silently collapse into one bit, so the mask alone
        // cannot show it.
        let types = InputCapture.capturedEventTypes
        XCTAssertEqual(Set(types.map(\.rawValue)).count, types.count)
    }
}
