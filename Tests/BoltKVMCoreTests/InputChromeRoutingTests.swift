import XCTest
import AppKit
@testable import BoltKVMCore

/// The fullscreen toolbar sits above the shifted picture. A click at or above
/// the picture's top edge must stay local; only points inside the picture may be
/// forwarded to the remote Mac. This is the regression guard for the
/// "toolbar click goes through to the app below" bug.
final class InputChromeRoutingTests: XCTestCase {
    private let videoTop: CGFloat = 1640

    func testPointInsideToolbarBandIsChrome() {
        XCTAssertTrue(WindowInputCapture.pointerIsInChrome(pointerY: 1690, videoTop: videoTop))
        XCTAssertTrue(WindowInputCapture.pointerIsInChrome(pointerY: 1641, videoTop: videoTop))
    }

    func testPointInsidePictureIsNotChrome() {
        XCTAssertFalse(WindowInputCapture.pointerIsInChrome(pointerY: 1639, videoTop: videoTop))
        XCTAssertFalse(WindowInputCapture.pointerIsInChrome(pointerY: 0, videoTop: videoTop))
    }

    func testPictureTopEdgeItselfIsNotChrome() {
        XCTAssertFalse(WindowInputCapture.pointerIsInChrome(pointerY: videoTop, videoTop: videoTop))
    }
}
