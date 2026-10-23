import XCTest
@testable import BoltKVMCore

/// The GUI colour pipeline is capture(BT.709 video range) → ProRes → shader.
/// If the shader expands luma but not chroma, every colour comes back duller;
/// these are the numbers that made "色彩不如直连屏" visible.
final class ColorMathTests: XCTestCase {
    private func assertRGB(_ got: (r: Double, g: Double, b: Double),
                           _ want: (Double, Double, Double), _ label: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.r, want.0, accuracy: 0.02, "\(label) r", file: file, line: line)
        XCTAssertEqual(got.g, want.1, accuracy: 0.02, "\(label) g", file: file, line: line)
        XCTAssertEqual(got.b, want.2, accuracy: 0.02, "\(label) b", file: file, line: line)
    }

    func testPureRedSurvivesTheRoundTrip() {
        let enc = ColorMath.videoRangeYCbCr(r: 1, g: 0, b: 0)
        // What the encoder puts on the wire: Y≈63, Cb≈102, Cr≈240.
        XCTAssertEqual(enc.y * 255, 63, accuracy: 2)
        XCTAssertEqual(enc.cr * 255, 240, accuracy: 2)
        let rgb = ColorMath.rgb(y: enc.y, cb: enc.cb, cr: enc.cr, fullRange: false, tenBit: false)
        assertRGB(rgb, (1, 0, 0), "video-range red")
    }

    func testMidGrayStaysNeutral() {
        let enc = ColorMath.videoRangeYCbCr(r: 0.5, g: 0.5, b: 0.5)
        let rgb = ColorMath.rgb(y: enc.y, cb: enc.cb, cr: enc.cr, fullRange: false, tenBit: false)
        assertRGB(rgb, (0.5, 0.5, 0.5), "gray")
    }

    func testBlackAndWhiteHitTheEnds() {
        let black = ColorMath.rgb(y: 16.0 / 255.0, cb: 0.5, cr: 0.5, fullRange: false, tenBit: false)
        assertRGB(black, (0, 0, 0), "black")
        let white = ColorMath.rgb(y: 235.0 / 255.0, cb: 0.5, cr: 0.5, fullRange: false, tenBit: false)
        assertRGB(white, (1, 1, 1), "white")
    }

    /// The bug that was shipped: luma expanded, chroma left compressed. Red came
    /// back at (231, 6, 7) — a 12% saturation loss that reads as "dull colours".
    func testChromaMustBeExpandedToo() {
        let y = 63.0 / 255.0, cb = 102.0 / 255.0, cr = 240.0 / 255.0
        let correct = ColorMath.rgb(y: y, cb: cb, cr: cr, fullRange: false, tenBit: false)
        XCTAssertEqual(correct.r, 1.0, accuracy: 0.02)

        let old = (y - 16.0 / 255.0) * (255.0 / 219.0)
        let oldR = old + 1.5748 * (cr - 0.5)
        XCTAssertLessThan(oldR, 0.95, "the old formula must fail this, otherwise the test proves nothing")
    }

    func testTenBitVideoRangeMatchesEightBit() {
        // Same colour at 10-bit depth: Y 64…940, chroma 64…960.
        let enc = ColorMath.videoRangeYCbCr(r: 1, g: 0, b: 0)
        // enc.y is the *encoded* luma; undo the 8-bit video range first.
        let linearY = (enc.y - 16.0 / 255.0) * (255.0 / 219.0)
        let y10 = (64.0 + 876.0 * linearY) / 1023.0
        let cb10 = (512.0 + 896.0 * (enc.cb - 128.0 / 255.0) / (224.0 / 255.0)) / 1023.0
        let cr10 = (512.0 + 896.0 * (enc.cr - 128.0 / 255.0) / (224.0 / 255.0)) / 1023.0
        let rgb = ColorMath.rgb(y: y10, cb: cb10, cr: cr10, fullRange: false, tenBit: true)
        assertRGB(rgb, (1, 0, 0), "10-bit video-range red")
    }
}
