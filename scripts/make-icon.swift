// Draws the app icon and emits AppIcon.icns. No design tools, no assets in the
// repo: the icon is code, so it stays in sync and rebuilds deterministically.
//
//   swift scripts/make-icon.swift Packaging/AppIcon.icns
import AppKit
import Foundation

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size

    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.22, yRadius: s * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

    let ink = NSColor(calibratedWhite: 0.93, alpha: 1)
    let screen = NSBezierPath(roundedRect: NSRect(x: s * 0.15, y: s * 0.30, width: s * 0.70, height: s * 0.44),
                              xRadius: s * 0.055, yRadius: s * 0.055)
    ink.setStroke()
    screen.lineWidth = s * 0.032
    screen.stroke()

    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: s * 0.5, y: s * 0.30))
    stand.line(to: NSPoint(x: s * 0.5, y: s * 0.215))
    stand.lineWidth = s * 0.032
    ink.setStroke()
    stand.stroke()

    let base = NSBezierPath(roundedRect: NSRect(x: s * 0.35, y: s * 0.155, width: s * 0.30, height: s * 0.05),
                            xRadius: s * 0.025, yRadius: s * 0.025)
    ink.setFill()
    base.fill()

    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: s * 0.57, y: s * 0.67))
    bolt.line(to: NSPoint(x: s * 0.40, y: s * 0.485))
    bolt.line(to: NSPoint(x: s * 0.50, y: s * 0.485))
    bolt.line(to: NSPoint(x: s * 0.44, y: s * 0.345))
    bolt.line(to: NSPoint(x: s * 0.63, y: s * 0.525))
    bolt.line(to: NSPoint(x: s * 0.53, y: s * 0.525))
    bolt.close()
    NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.13, alpha: 1).setFill()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging/AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = draw(size: CGFloat(px))
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: tmp.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", out]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(out)")
