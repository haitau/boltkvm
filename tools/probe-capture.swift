// probe-capture.swift
//
// M0 capture-surface probe. Run on the headless/controlled Mac.
//
// Prints:
//   1. CGGetActiveDisplayList: display ID, logical bounds, pixel mode
//   2. ScreenCaptureKit shareable displays (SCDisplay width/height/frame)
//   3. One SCScreenshotManager frame: actual image pixel dimensions
//   4. The PNG path for visual inspection
//
// Build:  swiftc -O tools/probe-capture.swift -o /tmp/probe-capture
// Run:    /tmp/probe-capture [output.png]
//
// ScreenCaptureKit requires the Screen Recording TCC permission. The probe
// reports preflight state and the exact SCK error instead of failing silently.

import Foundation
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

func printCGDisplays() {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else {
        print("CGGetActiveDisplayList(count) failed")
        return
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        print("CGGetActiveDisplayList(list) failed")
        return
    }

    print("== CG active displays (\(count)) ==")
    for id in ids {
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        let pw = mode?.pixelWidth ?? -1
        let ph = mode?.pixelHeight ?? -1
        let lw = mode?.width ?? -1
        let lh = mode?.height ?? -1
        let hz = mode?.refreshRate ?? -1
        let main = CGDisplayIsMain(id) != 0 ? "main" : "-"
        let builtin = CGDisplayIsBuiltin(id) != 0 ? "builtin" : "-"
        print(String(
            format: "id=%u bounds=%.0fx%.0f modePixel=%dx%d modeLogical=%dx%d @%.2fHz %@ %@",
            id, bounds.width, bounds.height, pw, ph, lw, lh, hz, main, builtin
        ))
    }
}

func savePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationCreateWithURL failed"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationFinalize failed"])
    }
}

@main
struct Probe {
    static func main() async {
        let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/probe-capture.png"

        print("== TCC preflight ==")
        print("CGPreflightScreenCaptureAccess = \(CGPreflightScreenCaptureAccess())")

        printCGDisplays()

        do {
            print("== SCShareableContent ==")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("displays=\(content.displays.count) windows=\(content.windows.count) apps=\(content.applications.count)")
            for d in content.displays {
                let m = CGDisplayCopyDisplayMode(d.displayID)
                print("SCDisplay id=\(d.displayID) points=\(d.width)x\(d.height) modePixel=\(m?.pixelWidth ?? -1)x\(m?.pixelHeight ?? -1) frame=\(d.frame)")
            }

            // Pick the largest pixel-area display: the 3008x1692 HiDPI virtual
            // display has a 6016x3384 backing store.
            func pixelArea(_ d: SCDisplay) -> Int {
                let m = CGDisplayCopyDisplayMode(d.displayID)
                return (m?.pixelWidth ?? d.width) * (m?.pixelHeight ?? d.height)
            }
            guard let display = content.displays.max(by: { pixelArea($0) < pixelArea($1) }) else {
                print("ERROR: no SCDisplay available")
                exit(3)
            }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelW = mode?.pixelWidth ?? display.width
            let pixelH = mode?.pixelHeight ?? display.height
            print("== capture target ==")
            print("SCDisplay id=\(display.displayID) points=\(display.width)x\(display.height) pixel=\(pixelW)x\(pixelH)")

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = pixelW
            config.height = pixelH
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false

            print("== SCScreenshotManager ==")
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            print("captured image: \(image.width)x\(image.height) bytesPerRow=\(image.bytesPerRow) colorSpace=\(String(describing: image.colorSpace?.name))")
            try savePNG(image, to: outPath)
            print("saved: \(outPath)")
        } catch {
            print("ERROR: \(error)")
            print("ERROR localized: \(error.localizedDescription)")
            exit(2)
        }
    }
}
