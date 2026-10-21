// vt-probe.swift
//
// M1 feasibility probe: can this Mac create a low-latency HEVC
// VTCompressionSession at 6016×3384 (or an arbitrary size), and can it
// actually encode synthetic frames? Run on the machine that will capture.
//
// Build: swiftc -O -parse-as-library tools/vt-probe.swift -o /tmp/vt-probe
// Run:   /tmp/vt-probe [width] [height] [frames]

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

final class ProbeContext {
    var encoded = 0
    var bytes = 0
    var keyframes = 0
    var firstFrameSeconds: Double = 0
    var lastPTS: CMTime = .invalid
    let start = DispatchTime.now().uptimeNanoseconds
    let done = DispatchSemaphore(value: 0)
    let inFlight = DispatchSemaphore(value: 4)
    var firstCallback: UInt64 = 0
    var lastCallback: UInt64 = 0
    var dropped = 0

    func note(_ sbuf: CMSampleBuffer) {
        let data = CMSampleBufferGetDataBuffer(sbuf)
        let length = data.map { CMBlockBufferGetDataLength($0) } ?? 0
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        encoded += 1
        bytes += length
        if !notSync { keyframes += 1 }
        if encoded == 1 {
            firstFrameSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            print("first encoded frame: \(length) bytes keyframe=\(!notSync) after \(String(format: "%.3f", firstFrameSeconds))s")
        }
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sbuf)
        let now = DispatchTime.now().uptimeNanoseconds
        if firstCallback == 0 { firstCallback = now }
        lastCallback = now
        inFlight.signal()
        if encoded >= frameTarget { done.signal() }
    }

    var frameTarget = 10
}

let args = CommandLine.arguments
let width = args.count > 1 ? Int(args[1]) ?? 6016 : 6016
let height = args.count > 2 ? Int(args[2]) ?? 3384 : 3384
let frames = args.count > 3 ? Int(args[3]) ?? 180 : 180

print("== VideoToolbox HEVC probe \(width)x\(height) x\(frames) ==")
print("HEVC hardware decode supported: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))")

func printEncoderList() {
    var listRef: CFArray?
    let status = VTCopyVideoEncoderList(nil, &listRef)
    guard status == noErr, let list = listRef as? [[String: Any]] else {
        print("VTCopyVideoEncoderList failed: \(status)")
        return
    }
    print("== HEVC encoders ==")
    for e in list {
        let codec = e[kVTVideoEncoderList_CodecType as String] as? Int ?? 0
        guard codec == kCMVideoCodecType_HEVC else { continue }
        let name = e[kVTVideoEncoderList_EncoderName as String] as? String ?? "?"
        let id = e[kVTVideoEncoderList_EncoderID as String] as? String ?? "?"
        let hw = e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false
        print("name=\(name) id=\(id) hardware=\(hw)")
    }
}
printEncoderList()

let spec: [CFString: Any] = [
    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
]

var session: VTCompressionSession?
let ctx = ProbeContext()
ctx.frameTarget = frames
let refcon = Unmanaged.passUnretained(ctx).toOpaque()

let createStatus = VTCompressionSessionCreate(
    allocator: kCFAllocatorDefault,
    width: Int32(width),
    height: Int32(height),
    codecType: kCMVideoCodecType_HEVC,
    encoderSpecification: spec as CFDictionary,
    imageBufferAttributes: nil,
    compressedDataAllocator: nil,
    outputCallback: { (refcon, sourceFrameRefcon, status, flags, sampleBuffer) in
        let c = Unmanaged<ProbeContext>.fromOpaque(refcon!).takeUnretainedValue()
        if flags.contains(.frameDropped) { c.dropped += 1 }
        guard status == noErr, let sbuf = sampleBuffer else {
            c.inFlight.signal()
            return
        }
        c.note(sbuf)
    },
    refcon: refcon,
    compressionSessionOut: &session
)
print("VTCompressionSessionCreate: \(createStatus)")
guard createStatus == noErr, let session else {
    print("RESULT: FAILED to create HEVC encoder session at \(width)x\(height)")
    exit(1)
}

var usingHW: CFTypeRef?
let hwStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &usingHW)
print("using hardware encoder: status=\(hwStatus) value=\(String(describing: usingHW))")

let props: [CFString: Any] = [
    kVTCompressionPropertyKey_RealTime: true,
    kVTCompressionPropertyKey_AllowFrameReordering: false,
    kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
    kVTCompressionPropertyKey_ExpectedFrameRate: 60,
    kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
    kVTCompressionPropertyKey_AverageBitRate: 150_000_000,
]
for (key, value) in props {
    let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
    print("set \(key): \(status)")
}

// Low-latency rate control may override / require DataRateLimits. Try both.
let limits: [Any] = [150_000_000 / 8, 1]
let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
print("set DataRateLimits: \(limitStatus)")

func makeNoiseBuffer(seed: UInt32) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    let st = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attrs as CFDictionary, &pb
    )
    guard st == kCVReturnSuccess, let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    var s = seed
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { continue }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let h = plane == 0 ? height : height / 2
        let p = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(bpr * h) {
            s = s &* 1664525 &+ 1013904223
            p[i] = UInt8(truncatingIfNeeded: s >> 24)
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

print("allocating two noise frame buffers...")
guard let bufA = makeNoiseBuffer(seed: 0x12345678),
      let bufB = makeNoiseBuffer(seed: 0x9ABCDEF0) else {
    print("RESULT: FAILED to allocate pixel buffers")
    exit(1)
}
print("noise buffers ready")

let encodeStart = DispatchTime.now().uptimeNanoseconds
for i in 0..<frames {
    let pts = CMTime(value: CMTimeValue(i), timescale: 60)
    let dur = CMTime(value: 1, timescale: 60)
    let status = VTCompressionSessionEncodeFrame(
        session,
        imageBuffer: (i % 2 == 0 ? bufA : bufB),
        presentationTimeStamp: pts,
        duration: dur,
        frameProperties: nil,
        sourceFrameRefcon: nil,
        infoFlagsOut: nil
    )
    if status != noErr { print("EncodeFrame \(i) failed: \(status)") }
    // Keep at most 4 frames in the encoder to avoid unbounded queueing.
    _ = ctx.inFlight.wait(timeout: .now() + 5)
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
if ctx.done.wait(timeout: .now() + 10) == .timedOut {
    print("timed out waiting for encoder callbacks (got \(ctx.encoded)/\(frames))")
}
let activeEnd = ctx.lastCallback != 0 ? ctx.lastCallback : DispatchTime.now().uptimeNanoseconds
let elapsed = Double(activeEnd - encodeStart) / 1e9
let wallElapsed = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1e9
let fps = elapsed > 0 ? Double(ctx.encoded) / elapsed : 0
let mbps = elapsed > 0 ? Double(ctx.bytes) * 8 / elapsed / 1e6 : 0
print("encoded=\(ctx.encoded) keyframes=\(ctx.keyframes) dropped=\(ctx.dropped) bytes=\(ctx.bytes) activeElapsed=\(String(format: "%.3f", elapsed))s wall=\(String(format: "%.3f", wallElapsed))s fps=\(String(format: "%.1f", fps)) bitrate=\(String(format: "%.1f", mbps)) Mbps")
print("RESULT: \(ctx.encoded > 0 ? "OK" : "FAILED") \(width)x\(height) HEVC")
VTCompressionSessionInvalidate(session)
