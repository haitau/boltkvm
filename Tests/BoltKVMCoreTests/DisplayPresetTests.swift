import XCTest
@testable import BoltKVMCore

final class DisplayPresetTests: XCTestCase {
    /// The two setups this project actually runs on lead the list: the 32" HKC
    /// over Thunderbolt Bridge at the office, then the MacBook Pro panel at home.
    func testPrimaryPresetsComeFirst() {
        let presets = Prefs.displayPresets
        XCTAssertEqual(presets[0].0, "3008x1692")
        XCTAssertEqual(presets[0].1, 3008)
        XCTAssertEqual(presets[0].2, 1692)
        XCTAssertEqual(presets[1].0, "1728x1117")
        XCTAssertEqual(presets[1].1, 1728)
        XCTAssertEqual(presets[1].2, 1117)
    }

    /// Two primary + four everyday sizes, without duplicates or the old
    /// pixel-sized 5120/6016 entries (they would ask for a 10240-wide backing).
    func testPresetListIsOrderedAndUnique() {
        let specs = Prefs.displayPresets.map { "\($0.1)x\($0.2)" }
        XCTAssertEqual(specs, [
            "3008x1692", "1728x1117",
            "1920x1080", "2560x1440", "2880x1620", "3840x2160",
        ])
        XCTAssertEqual(Set(specs).count, specs.count)
    }

    func testDisplaySizeAcceptsMacBookLooksLikeSize() {
        let size = DisplaySize.parse("1728×1117")
        XCTAssertEqual(size?.width, 1728)
        XCTAssertEqual(size?.height, 1117)
    }

    func testDisplaySizeAcceptsWhitespaceAndPlainX() {
        let size = DisplaySize.parse(" 3008 x 1692 ")
        XCTAssertEqual(size?.width, 3008)
        XCTAssertEqual(size?.height, 1692)
    }

    func testDisplaySizeRejectsOutOfRangeAndGarbage() {
        XCTAssertNil(DisplaySize.parse("639x480"))
        XCTAssertNil(DisplaySize.parse("7681x4320"))
        XCTAssertNil(DisplaySize.parse("1920x479"))
        XCTAssertNil(DisplaySize.parse("1920x4321"))
        XCTAssertNil(DisplaySize.parse("1920"))
        XCTAssertNil(DisplaySize.parse("wide×tall"))
    }

    /// 1728×1117 is odd at the logical level but its 2x backing (3456×2234) is
    /// even. A 1x stream would be 1117 tall, so the capture side rounds down.
    func testEvenVideoSizeRoundsOddDimensions() {
        XCTAssertEqual(evenVideoSize(width: 3456, height: 2234).width, 3456)
        XCTAssertEqual(evenVideoSize(width: 3456, height: 2234).height, 2234)
        XCTAssertEqual(evenVideoSize(width: 1728, height: 1117).width, 1728)
        XCTAssertEqual(evenVideoSize(width: 1728, height: 1117).height, 1116)
        XCTAssertEqual(evenVideoSize(width: 1, height: 1).width, 2)
        XCTAssertEqual(evenVideoSize(width: 1, height: 1).height, 2)
    }
}
