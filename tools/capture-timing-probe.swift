// capture-timing-probe.swift
//
// Isolate ScreenCaptureKit frame delivery from encode/decode. Counts frames and
// inter-frame intervals for a fixed duration.
//
// Build: swiftc -O -parse-as-library tools/capture-timing-probe.swift -o /tmp/ct-probe
// Run on the controlled Mac from a GUI app with Screen Recording TCC:
//   /tmp/ct-probe <width> <height> <seconds> [queueDepth] [minIntervalNum] [minIntervalDen]

import Foundation
import CoreMedia
import ScreenCaptureKit

final class Sink: NSObject, SCStreamOutput {
    private let lock = NSLock()
    var frames = 0
    var last: UInt64 = 0
    var intervals: [Double] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        frames += 1
        if last != 0 { intervals.append(Double(now - last) / 1e6) }
        last = now
        lock.unlock()
    }

    func report(seconds: Double) {
        lock.lock()
        let f = frames
        let iv = intervals
        lock.unlock()
        let sorted = iv.sorted()
        let avg = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxv = sorted.last ?? 0
        let minv = sorted.first ?? 0
        print(String(format: "captured=%d fps=%.1f interval avg=%.2fms p95=%.2fms max=%.2fms min=%.2fms",
                     f, Double(f) / seconds, avg, p95, maxv, minv))
    }
}

@main
struct CaptureTimingProbe {
    static func main() async {
        let a = CommandLine.arguments
        let width = a.count > 1 ? Int(a[1]) ?? 3840 : 3840
        let height = a.count > 2 ? Int(a[2]) ?? 2160 : 2160
        let seconds = a.count > 3 ? Double(a[3]) ?? 15 : 15
        let qd = a.count > 4 ? Int(a[4]) ?? 5 : 5
        let num = a.count > 5 ? Int(a[5]) ?? 1 : 1
        let den = a.count > 6 ? Int(a[6]) ?? 60 : 60
        print("== capture timing \(width)x\(height) \(seconds)s queue=\(qd) interval=\(num)/\(den) ==")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            func area(_ d: SCDisplay) -> Int {
                let m = CGDisplayCopyDisplayMode(d.displayID)
                return (m?.pixelWidth ?? d.width) * (m?.pixelHeight ?? d.height)
            }
            guard let display = content.displays.max(by: { area($0) < area($1) }) else { exit(3) }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            print("display \(display.displayID) points=\(display.width)x\(display.height) pixel=\(mode?.pixelWidth ?? -1)x\(mode?.pixelHeight ?? -1) refresh=\(mode?.refreshRate ?? -1)")
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = width
            cfg.height = height
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.minimumFrameInterval = CMTime(value: CMTimeValue(num), timescale: CMTimeScale(den))
            cfg.queueDepth = qd
            cfg.showsCursor = true
            cfg.capturesAudio = false
            let sink = Sink()
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ct", qos: .userInteractive))
            try await stream.startCapture()
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try await stream.stopCapture()
            sink.report(seconds: seconds)
        } catch {
            print("ERROR: \(error)")
            exit(2)
        }
    }
}
