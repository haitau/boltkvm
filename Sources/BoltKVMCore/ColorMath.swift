import Foundation

/// BT.709 YCbCr → non-linear RGB, the same conversion as the Metal fragment
/// shader in `Renderer`.
///
/// It lives here so the range expansion can be unit-tested: the shader is a
/// string, so a wrong constant there is invisible until someone looks at the
/// screen. Keep the two in sync; the test states the expected numbers.
enum ColorMath {
    /// - Parameters:
    ///   - y, cb, cr: sample values normalised to 0…1 as the texture returns them
    ///     (so 8-bit 63 is 63/255).
    ///   - fullRange: JPEG-style full range instead of video range.
    ///   - tenBit: samples came from a 10-bit (64…940 luma, 64…960 chroma) buffer.
    /// - Returns: RGB in 0…1, BT.709 primaries.
    static func rgb(y: Double, cb: Double, cr: Double,
                    fullRange: Bool, tenBit: Bool) -> (r: Double, g: Double, b: Double) {
        let yy: Double
        let b: Double
        let r: Double
        if tenBit {
            let y10 = y * 1023
            let c10b = cb * 1023
            let c10r = cr * 1023
            if fullRange {
                yy = y10 / 1023
                b = c10b / 1023 - 0.5
                r = c10r / 1023 - 0.5
            } else {
                yy = (y10 - 64) / (940 - 64)
                b = (c10b - 512) / (960 - 64)
                r = (c10r - 512) / (960 - 64)
            }
        } else if fullRange {
            yy = y
            b = cb - 0.5
            r = cr - 0.5
        } else {
            yy = (y - 16.0 / 255.0) * (255.0 / 219.0)
            b = (cb - 128.0 / 255.0) * (255.0 / 224.0)
            r = (cr - 128.0 / 255.0) * (255.0 / 224.0)
        }
        return (yy + 1.5748 * r, yy - 0.1873 * b - 0.4681 * r, yy + 1.8556 * b)
    }

    /// BT.709 video-range encoding of an RGB triple, the inverse of `rgb`.
    /// Used by the tests (and to document what the encoder side produces).
    static func videoRangeYCbCr(r: Double, g: Double, b: Double) -> (y: Double, cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556
        let cr = (r - y) / 1.5748
        return (16.0 / 255.0 + (219.0 / 255.0) * y,
                128.0 / 255.0 + (224.0 / 255.0) * cb,
                128.0 / 255.0 + (224.0 / 255.0) * cr)
    }
}
