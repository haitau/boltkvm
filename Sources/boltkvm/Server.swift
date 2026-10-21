import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import VideoToolbox
import Darwin

final class Server: NSObject, SCStreamOutput {
    let captureWidth: Int
    let captureHeight: Int
    let codec: VideoCodec
    let connection: TCPConnection
    let dumpPath: String?
    private var dumped = false

    private var stream: SCStream?
    private var session: VTCompressionSession?
    private let sendQueue = DispatchQueue(label: "boltkvm.send")
    private let lock = NSLock()

    private var inFlight: DispatchSemaphore
    private struct FeedStamp { let host: UInt64; let wall: Int64 }
    private var feedTimes: [Int64: FeedStamp] = [:]

    private var captured = 0
    private var encoded = 0
    private var sent = 0
    private var dropped = 0
    private var bytes = 0
    private var keyframes = 0
    private var latencySum: Double = 0
    private var latencyCount = 0
    private var pending = 0
    private var formatKey: String?
    private var closed = false
    private var startTime = DispatchTime.now().uptimeNanoseconds

    init(width: Int, height: Int, codec: VideoCodec, connection: TCPConnection, dumpPath: String?) {
        self.captureWidth = width
        self.captureHeight = height
        self.codec = codec
        self.connection = connection
        self.dumpPath = dumpPath
        // HEVC needs ~4 frames in flight to sustain 60fps (its encoder
        // pipeline is ~20ms). ProRes is ~9ms, so two are enough and keep the
        // queue shorter.
        self.inFlight = DispatchSemaphore(value: codec == .prores422 ? 2 : 4)
        super.init()
    }

    func start() async throws {
        signal(SIGPIPE, SIG_IGN)
        startClockResponder()

        var s: VTCompressionSession?
        // M1 measurement: hardware HEVC without low-latency rate control gave
        // 57fps vs 51fps with it, at the same ~18ms encode latency. The bridge
        // has ample bandwidth, so we prefer the higher frame rate.
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let vtCodec: CMVideoCodecType = codec == .prores422 ? kCMVideoCodecType_AppleProRes422 : kCMVideoCodecType_HEVC
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(captureWidth),
            height: Int32(captureHeight),
            codecType: vtCodec,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                let server = Unmanaged<Server>.fromOpaque(refcon!).takeUnretainedValue()
                server.onEncoded(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: refcon,
            compressionSessionOut: &s
        )
        guard st == noErr, let s else {
            throw NSError(domain: "boltkvm", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate \(st)"])
        }
        session = s

        var props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
        ]
        if codec == .hevc {
            props[kVTCompressionPropertyKey_AllowFrameReordering] = false
            props[kVTCompressionPropertyKey_ProfileLevel] = kVTProfileLevel_HEVC_Main_AutoLevel
            props[kVTCompressionPropertyKey_MaxKeyFrameInterval] = 60
            props[kVTCompressionPropertyKey_AverageBitRate] = 120_000_000
        }
        for (k, v) in props {
            let rst = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if rst != noErr { log("encoder property \(k) -> \(rst)") }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        func area(_ d: SCDisplay) -> Int {
            let m = CGDisplayCopyDisplayMode(d.displayID)
            return (m?.pixelWidth ?? d.width) * (m?.pixelHeight ?? d.height)
        }
        guard let display = content.displays.max(by: { area($0) < area($1) }) else {
            throw NSError(domain: "boltkvm", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        log("capture display id=\(display.displayID) points=\(display.width)x\(display.height) pixel=\(mode?.pixelWidth ?? -1)x\(mode?.pixelHeight ?? -1) -> \(captureWidth)x\(captureHeight)")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 0, timescale: 1)
        config.queueDepth = 8
        config.showsCursor = true
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "boltkvm.capture", qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
        startTime = DispatchTime.now().uptimeNanoseconds
        log("capture started; waiting for frames")
    }

    private func dumpFrame(_ pb: CVPixelBuffer) {
        guard let path = dumpPath else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else {
            log("dump: createCGImage failed")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            log("dump: destination failed")
            return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        log("dump: \(path) \(cg.width)x\(cg.height) ok=\(CGImageDestinationFinalize(dest))")
    }

    private func startClockResponder() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let hd = try self.connection.recvExact(HEADER_SIZE)
                    guard let h = PacketHeader.decode(hd) else { break }
                    let payload = try self.connection.recvExact(Int(h.payloadLength))
                    if h.type == .timeSync {
                        let t1 = h.ptsMicros
                        let t2 = Int64(Date().timeIntervalSince1970 * 1_000_000)
                        var echo = Data()
                        echo.appendInt64BE(t1)
                        try self.connection.send(packet(type: .timeSync, ptsMicros: t2, payload: echo))
                        _ = payload
                    }
                } catch {
                    break
                }
            }
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        stream = nil
        session = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        captured += 1
        feedTimes[Int64(pts.value)] = FeedStamp(host: now, wall: Int64(Date().timeIntervalSince1970 * 1_000_000))
        let shouldDump = dumpPath != nil && !dumped && captured == 30
        if shouldDump { dumped = true }
        lock.unlock()
        if shouldDump { dumpFrame(pb) }

        if inFlight.wait(timeout: .now()) == .timedOut {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }
        guard let session else { return }
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb,
            presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
        if st != noErr {
            inFlight.signal()
            lock.lock(); dropped += 1; lock.unlock()
        }
    }

    // MARK: VT output

    private func onEncoded(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if flags.contains(.frameDropped) { dropped += 1 }
        let sbuf = sampleBuffer
        if let sbuf, status == noErr {
            encoded += 1
            if let fmt = CMSampleBufferGetFormatDescription(sbuf) {
                let sets = codec == .hevc ? (Self.extractParameterSets(fmt) ?? []) : []
                let key = codec == .prores422 ? "prores" : sets.map { $0.map { String(format: "%02x", $0) }.joined() }.joined(separator: "|")
                if (codec == .hevc && !sets.isEmpty) || codec == .prores422,
                   key != formatKey {
                    formatKey = key
                    let f = StreamFormat(width: captureWidth, height: captureHeight, codec: codec, parameterSets: sets)
                    sendQueue.async { [weak self] in
                        guard let self else { return }
                        do {
                            try self.connection.send(packet(type: .format, payload: f.encode()))
                            log("sent format \(self.captureWidth)x\(self.captureHeight) params=\(sets.count)")
                        } catch {
                            self.lock.lock(); self.closed = true; self.lock.unlock()
                            log("client gone on format")
                        }
                    }
                }
            }
            if let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) {
                let length = CMBlockBufferGetDataLength(dataBuffer)
                var data = Data(count: length)
                let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
                }
                if copyStatus == noErr {
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]]
                    let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                    let isKey = !notSync
                    if isKey { keyframes += 1 }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
                    var micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
                    if let feed = feedTimes.removeValue(forKey: Int64(pts.value)) {
                        latencySum += Double(now - feed.host) / 1e6
                        latencyCount += 1
                        micros = feed.wall
                    }
                    if closed { pending += 0 } else { pending += 1 }
                    bytes += length
                    if closed { dropped += 1 }
                    else if pending > 3 && !isKey {
                        pending -= 1
                        dropped += 1
                    } else {
                        sendQueue.async { [weak self] in
                            guard let self else { return }
                            do {
                                try self.connection.send(packet(type: .frame, flags: isKey ? 1 : 0, ptsMicros: micros, payload: data))
                                self.lock.lock(); self.sent += 1; self.pending -= 1; self.lock.unlock()
                            } catch {
                                self.lock.lock(); self.pending -= 1; self.closed = true; self.lock.unlock()
                                log("client gone; stopping send")
                            }
                        }
                    }
                }
            }
        }
        lock.unlock()
        inFlight.signal()

        if encoded > 0 && encoded % 120 == 0 {
            reportLine()
        }
    }

    private static func extractParameterSets(_ fmt: CMFormatDescription) -> [Data]? {
        var count = 0
        var probePtr: UnsafePointer<UInt8>?
        var probeSize = 0
        let first = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: &probePtr, parameterSetSizeOut: &probeSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        guard first == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if st == noErr, let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        return sets.isEmpty ? nil : sets
    }

    func reportLine() {
        lock.lock()
        let c = captured, e = encoded, s = sent, d = dropped, b = bytes, k = keyframes
        let lat = latencyCount > 0 ? latencySum / Double(latencyCount) : 0
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1e9
        lock.unlock()
        let fps = elapsed > 0 ? Double(e) / elapsed : 0
        let mbps = elapsed > 0 ? Double(b) * 8 / elapsed / 1e6 : 0
        log(String(format: "stats captured=%d encoded=%d sent=%d dropped=%d key=%d fps=%.1f bitrate=%.1fMbps encLat=%.2fms", c, e, s, d, k, fps, mbps, lat))
    }
}
