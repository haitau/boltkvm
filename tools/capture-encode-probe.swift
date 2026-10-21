// capture-encode-probe.swift
//
// M1 step 1: capture the virtual display with ScreenCaptureKit at a chosen
// pixel size and encode real desktop frames with VideoToolbox HEVC low-latency.
// Measures sustained capture→encode throughput and bitrate. No network yet.
//
// Build: swiftc -O -parse-as-library tools/capture-encode-probe.swift -o /tmp/ce-probe
// Run on the controlled Mac (needs Screen Recording TCC):
//   /tmp/ce-probe [width] [height] [seconds]
//
// ScreenCaptureKit requires the Screen Recording permission. From SSH the TCC
// preflight is false; launch this binary from a GUI app that already has the
// permission (e.g. Terminal) to inherit it.

import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

struct Config {
    var width: Int
    var height: Int
    var seconds: Double
    var mode: Int
}

final class Encoder {
    private var session: VTCompressionSession!
    private let lock = NSLock()
    private let inFlight = DispatchSemaphore(value: 4)
    private var feedTimes: [Int64: UInt64] = [:]

    var captured = 0
    var encoded = 0
    var dropped = 0
    var bytes = 0
    var keyframes = 0
    var firstFeed: UInt64 = 0
    var lastCallback: UInt64 = 0
    var latencySum: Double = 0
    var latencyMax: Double = 0
    var latencyCount = 0
    var reportedPixelFormat = false

    init(width: Int, height: Int, mode: Int) throws {
        var s: VTCompressionSession?
        var spec: [CFString: Any] = [:]
        var codec: CMVideoCodecType = kCMVideoCodecType_HEVC
        switch mode {
        case 10:
            codec = kCMVideoCodecType_H264
            spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        case 11:
            codec = kCMVideoCodecType_AppleProRes422
            spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        case 0:
            spec = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            ]
        case 1:
            spec = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ]
        case 2:
            spec = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_EncoderID: "com.apple.videotoolbox.videoencoder.ave.hevc",
            ]
        default:
            spec = [:]
        }
        print("encoder mode=\(mode) codec=\(codec) spec=\(spec.keys)")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                let enc = Unmanaged<Encoder>.fromOpaque(refcon!).takeUnretainedValue()
                enc.onEncoded(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: ctx,
            compressionSessionOut: &s
        )
        guard status == noErr, let s else {
            throw NSError(domain: "ce-probe", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed: \(status)"])
        }
        session = s

        var props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
        ]
        if codec == kCMVideoCodecType_HEVC {
            props[kVTCompressionPropertyKey_ProfileLevel] = kVTProfileLevel_HEVC_Main_AutoLevel
            props[kVTCompressionPropertyKey_AverageBitRate] = width >= 5000 ? 150_000_000 : 80_000_000
        } else if codec == kCMVideoCodecType_H264 {
            props[kVTCompressionPropertyKey_ProfileLevel] = kVTProfileLevel_H264_High_AutoLevel
            props[kVTCompressionPropertyKey_AverageBitRate] = 120_000_000
        }
        for (key, value) in props {
            let st = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
            if st != noErr { print("set \(key) -> \(st)") }
        }
    }

    func feed(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if !reportedPixelFormat {
            let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
            print(String(format: "input pixel format: 0x%08x", fmt))
            reportedPixelFormat = true
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if firstFeed == 0 { firstFeed = now }
        lock.lock()
        captured += 1
        feedTimes[pts.value] = now
        lock.unlock()

        if inFlight.wait(timeout: .now()) == .timedOut {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
        if status != noErr {
            inFlight.signal()
            lock.lock(); dropped += 1; lock.unlock()
        }
    }

    private func onEncoded(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if flags.contains(.frameDropped) { dropped += 1 }
        if let sbuf = sampleBuffer, status == noErr {
            let data = CMSampleBufferGetDataBuffer(sbuf)
            let length = data.map { CMBlockBufferGetDataLength($0) } ?? 0
            let att = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            encoded += 1
            bytes += length
            if !notSync { keyframes += 1 }
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            if let feed = feedTimes.removeValue(forKey: Int64(pts.value)) {
                let ms = Double(now - feed) / 1e6
                latencySum += ms
                latencyMax = max(latencyMax, ms)
                latencyCount += 1
            }
        }
        lastCallback = now
        lock.unlock()
        inFlight.signal()
    }

    func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        // Give the encoder a moment to drain the last few frames.
        Thread.sleep(forTimeInterval: 1.0)
        VTCompressionSessionInvalidate(session)
    }

    func report() {
        let end = lastCallback != 0 ? lastCallback : DispatchTime.now().uptimeNanoseconds
        let elapsed = firstFeed != 0 ? Double(end - firstFeed) / 1e9 : 0
        let fps = elapsed > 0 ? Double(encoded) / elapsed : 0
        let mbps = elapsed > 0 ? Double(bytes) * 8 / elapsed / 1e6 : 0
        let avgLat = latencyCount > 0 ? latencySum / Double(latencyCount) : 0
        print(String(format: "captured=%d encoded=%d dropped=%d keyframes=%d bytes=%d", captured, encoded, dropped, keyframes, bytes))
        print(String(format: "elapsed=%.3fs fps=%.1f bitrate=%.1f Mbps avgEncodeLatency=%.2fms max=%.2fms", elapsed, fps, mbps, avgLat, latencyMax))
    }
}

final class Sink: NSObject, SCStreamOutput {
    let encoder: Encoder
    init(encoder: Encoder) { self.encoder = encoder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder.feed(pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

func pickDisplay(_ content: SCShareableContent) -> SCDisplay? {
    func area(_ d: SCDisplay) -> Int {
        let m = CGDisplayCopyDisplayMode(d.displayID)
        return (m?.pixelWidth ?? d.width) * (m?.pixelHeight ?? d.height)
    }
    return content.displays.max(by: { area($0) < area($1) })
}

@main
struct CaptureEncodeProbe {
    static func main() async {
        let args = CommandLine.arguments
        let cfg = Config(
            width: args.count > 1 ? Int(args[1]) ?? 6016 : 6016,
            height: args.count > 2 ? Int(args[2]) ?? 3384 : 3384,
            seconds: args.count > 3 ? Double(args[3]) ?? 10 : 10,
            mode: args.count > 4 ? Int(args[4]) ?? 0 : 0
        )
        print("== capture-encode probe \(cfg.width)x\(cfg.height) for \(cfg.seconds)s ==")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = pickDisplay(content) else {
                print("no display")
                exit(3)
            }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            print("display id=\(display.displayID) points=\(display.width)x\(display.height) pixel=\(mode?.pixelWidth ?? -1)x\(mode?.pixelHeight ?? -1)")
            print("TCC preflight=\(CGPreflightScreenCaptureAccess())")

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = cfg.width
            config.height = cfg.height
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 5
            config.showsCursor = true
            config.capturesAudio = false

            let encoder = try Encoder(width: cfg.width, height: cfg.height, mode: cfg.mode)
            let sink = Sink(encoder: encoder)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture.sink", qos: .userInteractive))
            try await stream.startCapture()
            print("capture started")
            try await Task.sleep(nanoseconds: UInt64(cfg.seconds * 1_000_000_000))
            try await stream.stopCapture()
            encoder.finish()
            encoder.report()
        } catch {
            print("ERROR: \(error)")
            exit(2)
        }
    }
}
