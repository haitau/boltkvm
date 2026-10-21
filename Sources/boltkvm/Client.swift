import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

private func decoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVBuffer?,
    presentationTimeStamp: CMTime,
    duration: CMTime
) {
    guard let refcon = decompressionOutputRefCon else { return }
    let d = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
    d.handleDecoded(status: status, flags: infoFlags, imageBuffer: imageBuffer, pts: presentationTimeStamp)
}

final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let lock = NSLock()

    var renderer: Renderer?
    private var serverToLocalOffsetMicros: Int64 = 0
    private var clockSyncRTTms: Double = .infinity
    private var warnedClock = false
    var latencies: [Double] = []
    var recvLatencies: [Double] = []
    var decoded = 0
    var dropped = 0
    var lastDecodeLatencyMs: Double = 0
    var firstPacketAt: UInt64 = 0
    var lastDecodedAt: UInt64 = 0
    private var loggedPixelFormat = false

    func setClockOffset(_ offset: Int64, rttMs: Double) {
        lock.lock(); serverToLocalOffsetMicros = offset; clockSyncRTTms = rttMs; lock.unlock()
        if rttMs > 20 && !warnedClock {
            warnedClock = true
            log("time sync RTT \(String(format: "%.1f", rttMs))ms is high; latency metrics suppressed until a stable sample")
        }
    }

    func configure(_ f: StreamFormat) throws {
        var fmt: CMFormatDescription?
        if f.codec == .hevc {
            var keep = f.parameterSets
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            for ps in keep {
                ps.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        pointers.append(base.assumingMemoryBound(to: UInt8.self))
                    }
                }
                sizes.append(ps.count)
            }
            let st: OSStatus = pointers.withUnsafeBufferPointer { pbuf in
                sizes.withUnsafeBufferPointer { sbuf in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pbuf.baseAddress!,
                        parameterSetSizes: sbuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &fmt
                    )
                }
            }
            guard st == noErr, let fmt else {
                throw NSError(domain: "boltkvm", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "format desc \(st)"])
            }
            format = fmt
        } else {
            let st = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_AppleProRes422,
                width: Int32(f.width),
                height: Int32(f.height),
                extensions: nil,
                formatDescriptionOut: &fmt
            )
            guard st == noErr, let fmt else {
                throw NSError(domain: "boltkvm", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "prores format desc \(st)"])
            }
            format = fmt
        }

        if let old = session {
            VTDecompressionSessionInvalidate(old)
            session = nil
        }
        let pixelFormat: OSType = f.codec == .prores422
            ? kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var s: VTDecompressionSession?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decoderOutputCallback,
            decompressionOutputRefCon: refcon
        )
        let ds = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmt!,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &s
        )
        guard ds == noErr, let s else {
            throw NSError(domain: "boltkvm", code: Int(ds), userInfo: [NSLocalizedDescriptionKey: "VTDecompressionSessionCreate \(ds)"])
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        log("decoder ready \(f.width)x\(f.height) codec=\(f.codec) params=\(f.parameterSets.count)")
    }

    func decode(_ data: Data, ptsMicros: Int64) {
        guard let session, let format else { return }
        let offset = serverToLocalOffsetMicros
        lock.lock(); let syncRTT = clockSyncRTTms; lock.unlock()
        if syncRTT < 20 {
            let recvLatency = Double(Int64(Date().timeIntervalSince1970 * 1_000_000) - (ptsMicros - offset)) / 1000.0
            if recvLatency > 0 && recvLatency < 10_000 { recvLatencies.append(recvLatency) }
        }
        var bb: CMBlockBuffer?
        let bst = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &bb
        )
        guard bst == noErr, let bb else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: data.count)
        }
        let pts = CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sbuf: CMSampleBuffer?
        let sst = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sbuf
        )
        guard sst == noErr, let sbuf else { return }
        if firstPacketAt == 0 { firstPacketAt = DispatchTime.now().uptimeNanoseconds }
        let flags = VTDecodeFrameFlags(rawValue: 1) // EnableAsynchronousDecompression
        let dst = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sbuf, flags: flags, frameRefcon: nil, infoFlagsOut: nil)
        if dst != noErr {
            lock.lock(); dropped += 1; lock.unlock()
        }
    }

    func handleDecoded(status: OSStatus, flags: VTDecodeInfoFlags, imageBuffer: CVBuffer?, pts: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        let offset = serverToLocalOffsetMicros
        lock.lock()
        let syncRTT = clockSyncRTTms
        if status == noErr, let imageBuffer {
            if !loggedPixelFormat {
                loggedPixelFormat = true
                let f = CVPixelBufferGetPixelFormatType(imageBuffer)
                let chars = [24,16,8,0].map { String(UnicodeScalar(UInt8((f >> UInt32($0)) & 0xff))) }.joined()
                log("decoded pixel format 0x\(String(f, radix: 16)) '\(chars)' planes=\(CVPixelBufferGetPlaneCount(imageBuffer))")
            }
            decoded += 1
            lastDecodedAt = now
            let serverMicros = Int64(CMTimeGetSeconds(pts) * 1_000_000)
            if serverMicros > 0 {
                let localMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
                let latency = Double(localMicros - (serverMicros - offset)) / 1000.0
                if syncRTT < 20 && latency > 0 && latency < 10_000 { latencies.append(latency) }
            }
            let captureLocal = serverMicros - offset
            renderer?.submit(imageBuffer, captureLocalMicros: captureLocal)
        } else {
            dropped += 1
        }
        lock.unlock()
    }

    var elapsed: Double {
        guard firstPacketAt != 0, lastDecodedAt != 0 else { return 0 }
        return Double(lastDecodedAt - firstPacketAt) / 1e9
    }

    func report() {
        lock.lock()
        let d = decoded, dr = dropped
        let e = elapsed
        lock.unlock()
        let fps = e > 0 ? Double(d) / e : 0
        let sorted = latencies.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxv = sorted.last ?? 0
        let rsorted = recvLatencies.sorted()
        let rp50 = rsorted.isEmpty ? 0 : rsorted[rsorted.count / 2]
        let rp95 = rsorted.isEmpty ? 0 : rsorted[min(rsorted.count - 1, Int(Double(rsorted.count) * 0.95))]
        log(String(format: "decode decoded=%d failed=%d elapsed=%.3fs fps=%.1f recv p50=%.1fms p95=%.1fms decodeLatency p50=%.1fms p95=%.1fms max=%.1fms", d, dr, e, fps, rp50, rp95, p50, p95, maxv))
        if p95 > 33 { log("WARNING: decode latency P95 \(String(format: "%.1f", p95))ms exceeds 33ms budget") }
        if dr > 0 { log("WARNING: \(dr) decode failures") }
    }
}
