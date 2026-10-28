import XCTest
import AppKit
@testable import BoltKVMCore

/// Geometry guard for the fullscreen toolbar. The bug was that revealing the
/// toolbar resized the fullscreen window (content height shrank by the 52 pt
/// band), so the Metal drawable changed aspect and the remote picture was
/// rescaled. The picture must instead keep its size and move down as one piece.
final class ClientChromeLayoutTests: XCTestCase {
    private let content = CGSize(width: 3008, height: 1692)
    private let chrome: CGFloat = 52

    func testWindowedPictureSitsBelowChrome() {
        let frame = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: chrome, fullScreen: false, toolbarVisible: true
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 3008, height: 1640))
    }

    func testFullscreenToolbarHiddenUsesWholeScreen() {
        let frame = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: 0, fullScreen: true, toolbarVisible: false
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 3008, height: 1692))
    }

    func testFullscreenToolbarShownMovesPictureDownWithoutResizing() {
        let frame = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: chrome, fullScreen: true, toolbarVisible: true
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: -52, width: 3008, height: 1692))
        XCTAssertEqual(frame.width, content.width)
        XCTAssertEqual(frame.height, content.height,
                       "the drawable must not be resized: that is what distorted the picture")
    }

    func testFullscreenVisibleToolbarBandDoesNotUseTransparentChildHeight() {
        // The child window is 68 pt, but its bottom 16 pt is transparent and
        // the visible toolbar host is 52 pt. Shifting by 68 leaves a 16 pt
        // strip of desktop between toolbar and picture.
        let visible = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: 52, fullScreen: true, toolbarVisible: true
        )
        let childHeight = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: 68, fullScreen: true, toolbarVisible: true
        )
        XCTAssertEqual(visible, CGRect(x: 0, y: -52, width: 3008, height: 1692))
        XCTAssertEqual(childHeight.origin.y, -68,
                       "this is the old, gap-producing shift; keep the distinction explicit")
    }

    func testFullscreenMenuBarAndToolbarBandMovePictureByBoth() {
        // When the app menu bar pops out, the toolbar child moves down 30 pt;
        // the picture must move by 30 + 52, not by 52 or by the child's 68.
        let frame = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: 82, fullScreen: true, toolbarVisible: true
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: -82, width: 3008, height: 1692))
    }

    func testMissingChromeMeasuredBeforeLayoutDoesNotMovePicture() {
        let frame = ClientController.ChromeLayout.videoFrame(
            content: content, chrome: 0, fullScreen: true, toolbarVisible: true
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 3008, height: 1692))
    }

    func testChromeLargerThanWindowIsClamped() {
        let frame = ClientController.ChromeLayout.videoFrame(
            content: CGSize(width: 800, height: 40), chrome: 100,
            fullScreen: true, toolbarVisible: true
        )
        XCTAssertEqual(frame, CGRect(x: 0, y: -40, width: 800, height: 40))

        let windowed = ClientController.ChromeLayout.videoFrame(
            content: CGSize(width: 800, height: 40), chrome: 100,
            fullScreen: false, toolbarVisible: true
        )
        XCTAssertEqual(windowed, CGRect(x: 0, y: 0, width: 800, height: 0))
    }
}
