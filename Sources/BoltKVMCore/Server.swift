import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import VideoToolbox
import AVFoundation
import Darwin
import IOKit.pwr_mgt

final class Server: NSObject, SCStreamOutput {
    let captureWidth: Int
    let captureHeight: Int
    let codec: VideoCodec
    let connection: TCPConnection
    let dumpPath: String?
    /// When the virtual display is ours, capture exactly that one instead of
    /// guessing by area (the machine may also have a physical screen attached).
    let preferredDisplayID: CGDirectDisplayID?
    let audioEnabled: Bool
    /// Clipboard sharing is on by default; `--no-clipboard` turns it off.
    let clipboardEnabled: Bool
    /// Mute the controlled Mac's output while a client listens. Off by default:
    /// the default A-1 path pauses the current Now Playing app instead, leaving
    /// the device's mute/volume state untouched.
    let muteLocalOutput: Bool
    private let clipboardMaxItemBytes: Int
    private let clipboardMaxTransferBytes: Int64
    private var clipboard: ClipboardSync?
    private var localMute: AudioOutputMute?
    private var dumped = false

    private let audioTarget = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                            channels: 2, interleaved: true)!
    private var audioConverter: AVAudioConverter?
    private var audioSourceFormat: AVAudioFormat?
    private var audioPackets = 0
    private var audioBytes = 0
    private var audioLoggedSource = false

    private var stream: SCStream?
    private var session: VTCompressionSession?
    private let sendQueue = DispatchQueue(label: "boltkvm.send")
    /// Frames allowed to sit between encoder output and the socket. Above this
    /// the newest frame is dropped: a slow client must cost quality, not memory
    /// (a stalled client used to queue ~190 MB/s until the process died).
    private let sendCap = 4
    private let sendByteCap = 8 << 20
    private var queuedBytes = 0
    private var forceKeyframe = false
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
    private var displayBounds = CGRect.zero
    private var inputCount = 0
    /// Where the last injected event went; releases on disconnect use it.
    private var lastMousePoint: CGPoint?
    /// Modifier bits the remote is currently holding, as far as our injections
    /// are concerned (updated from the client's own event flags).
    private var injectedFlags: UInt64 = 0
    private var keyCount = 0
    private var scrollCount = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let lockState = NSLock()
    private var disconnectedFlag = false
    private var startTime = DispatchTime.now().uptimeNanoseconds

    /// How the stream is coloured. `.wide` asks ScreenCaptureKit for Display P3
    /// in 10-bit 4:2:2 and tags the ProRes bitstream accordingly; `.standard`
    /// keeps the 8-bit BT.709 path every previous build used.
    let colorMode: ColorMode

    init(width: Int, height: Int, codec: VideoCodec, connection: TCPConnection, dumpPath: String?,
         audioEnabled: Bool = false, preferredDisplayID: CGDirectDisplayID? = nil,
         colorMode: ColorMode = .standard, clipboardEnabled: Bool = true,
         muteLocalOutput: Bool = false, clipboardMaxItemBytes: Int = ClipboardSync.defaultMaxItemBytes,
         clipboardMaxTransferBytes: Int64 = 0) {
        self.colorMode = colorMode
        self.clipboardEnabled = clipboardEnabled
        self.muteLocalOutput = muteLocalOutput
        self.clipboardMaxItemBytes = min(max(1, clipboardMaxItemBytes), Int(UInt32.max) - 1024)
        self.clipboardMaxTransferBytes = max(0, clipboardMaxTransferBytes)
        // A logical size can be odd (1728×1117); VideoToolbox wants even.
        let even = evenVideoSize(width: width, height: height)
        self.captureWidth = even.width
        self.audioEnabled = audioEnabled
        self.captureHeight = even.height
        self.codec = codec
        self.connection = connection
        self.dumpPath = dumpPath
        self.preferredDisplayID = preferredDisplayID
        // HEVC needs ~4 frames in flight to sustain 60fps (its encoder
        // pipeline is ~20ms). ProRes is ~9ms, so two are enough and keep the
        // queue shorter.
        self.inFlight = DispatchSemaphore(value: codec == .prores422 ? 2 : 4)
        super.init()
    }

    func start() async throws {
        signal(SIGPIPE, SIG_IGN)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
            reason: "boltkvm server capture/encode"
        )
        if !CGPreflightScreenCaptureAccess() {
            throw NSError(domain: "boltkvm", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission missing; launch the server from the authorized GUI app (or grant it in System Settings > Privacy & Security > Screen Recording)"])
        }
        if !CGPreflightPostEventAccess() {
            log("warning: Accessibility/post-event permission missing; input injection will fail")
        }
        if clipboardEnabled {
            let sync = ClipboardSync(conn: connection, enabled: true,
                                     maxItemBytes: clipboardMaxItemBytes,
                                     maxTransferBytes: clipboardMaxTransferBytes)
            sync.start()
            clipboard = sync
        }
        startClockResponder()
        startHeartbeat()

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
        if colorMode == .wide {
            // Tag the bitstream so the decoder does not have to guess: P3
            // primaries, BT.709 transfer and YCbCr matrix (what Apple uses for
            // P3 video), matching what the shader inverts on the client.
            props[kVTCompressionPropertyKey_ColorPrimaries] = kCVImageBufferColorPrimaries_P3_D65
            props[kVTCompressionPropertyKey_TransferFunction] = kCVImageBufferTransferFunction_ITU_R_709_2
            props[kVTCompressionPropertyKey_YCbCrMatrix] = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
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

        // A sleeping display makes SCShareableContent report zero displays, which
        // surfaces as the opaque "no display" error. Declaring user activity wakes
        // it; retry briefly because the wake is asynchronous.
        var content: SCShareableContent? = nil
        for attempt in 0..<5 {
            var assertionID: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity(
                "boltkvm: wake display for capture" as CFString,
                kIOPMUserActiveLocal, &assertionID)
            if attempt > 0 { log("no display yet; waking display and retrying (\(attempt))") }
            do {
                let c = try await shareableContentWithTimeout()
                if !c.displays.isEmpty { content = c; break }
            } catch {
                log("shareable content attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == 4 { throw error }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        guard let content else {
            throw NSError(domain: "boltkvm", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display (display asleep and would not wake; try caffeinate -disu on the server)"])
        }
        func area(_ d: SCDisplay) -> Int {
            let m = CGDisplayCopyDisplayMode(d.displayID)
            return (m?.pixelWidth ?? d.width) * (m?.pixelHeight ?? d.height)
        }
        let chosen = preferredDisplayID.flatMap { id in content.displays.first { $0.displayID == id } }
        if preferredDisplayID != nil && chosen == nil {
            log("capture display \(preferredDisplayID!) not in SCShareableContent; falling back to largest")
        }
        guard let display = chosen ?? content.displays.max(by: { area($0) < area($1) }) else {
            throw NSError(domain: "boltkvm", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        displayBounds = CGDisplayBounds(display.displayID)
        log("capture display id=\(display.displayID) points=\(display.width)x\(display.height) pixel=\(mode?.pixelWidth ?? -1)x\(mode?.pixelHeight ?? -1) -> \(captureWidth)x\(captureHeight) bounds=\(displayBounds)")

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = captureWidth
        config.height = captureHeight
        // Wide gamut needs 4:2:2 10-bit and a P3 working space; ScreenCaptureKit
        // converts the screen into it, and ProRes 422 is 10-bit natively.
        config.pixelFormat = colorMode == .wide
            ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if colorMode == .wide {
            config.colorSpaceName = CGColorSpace.displayP3
        }
        log("colour: \(colorMode == .wide ? "wide gamut (Display P3, 10-bit 4:2:2)" : "standard (BT.709, 8-bit 4:2:0)")")
        config.minimumFrameInterval = CMTime(value: 0, timescale: 1)
        config.queueDepth = 8
        // Do not paint the remote cursor into the stream. The client already has
        // a cursor at the very position it forwards, so a second (lagging) one
        // arrives ~30-40 ms late and jitters over the local one — it reads as
        // "the mouse is jumping around" (reported 2026-10-22).
        config.showsCursor = false
        config.capturesAudio = audioEnabled
        if audioEnabled {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "boltkvm.capture", qos: .userInteractive))
        if audioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "boltkvm.audio", qos: .userInteractive))
        }
        try await stream.startCapture()
        self.stream = stream
        startTime = DispatchTime.now().uptimeNanoseconds
        log("capture started; waiting for frames")
        if audioEnabled {
            // The controlled Mac should not keep playing a track that is now
            // routed to the client. Pause the current Now Playing app instead
            // of muting the output device: the user can see why the music
            // stopped, and the Mac's own volume/mute state is never touched.
            performRemoteAction(.pauseMedia)
        }
        if audioEnabled && muteLocalOutput {
            let mute = AudioOutputMute()
            mute.start()
            localMute = mute
        }
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

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: sendQueue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let gone = self.closed; self.lock.unlock()
            if gone { return }
            do {
                try self.connection.send(packet(type: .heartbeat, ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000), payload: Data()))
            } catch {
                self.signalDisconnect()
            }
        }
        t.resume()
        heartbeatTimer = t
    }

    /// ScreenCaptureKit's first enumeration after a fresh virtual display can
    /// simply never call back: the client then sits at "connecting" forever and
    /// only a helper restart helps. Race it against a timeout so a stuck call
    /// becomes a retry instead of a hung session.
    private func shareableContentWithTimeout(seconds: Double = 5) async throws -> SCShareableContent {
        try await withThrowingTaskGroup(of: SCShareableContent.self) { group in
            group.addTask {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "boltkvm", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "shareable content timed out after \(Int(seconds))s"])
            }
            guard let first = try await group.next() else {
                throw NSError(domain: "boltkvm", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "shareable content produced nothing"])
            }
            group.cancelAll()
            return first
        }
    }

    private func startClockResponder() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let (h, payload) = try self.connection.recvFrame()
                    if h.type == .timeSync {
                        let t1 = h.ptsMicros
                        let t2 = Int64(Date().timeIntervalSince1970 * 1_000_000)
                        var echo = Data()
                        echo.appendInt64BE(t1)
                        try self.connection.send(packet(type: .timeSync, ptsMicros: t2, payload: echo))
                        _ = payload
                    } else if h.type == .input {
                        if let ev = InputEvent.decode(payload) {
                            self.inject(ev)
                        }
                    } else if h.type == .command {
                        if let raw = payload.first, let action = RemoteAction(rawValue: raw) {
                            self.performRemote(action)
                        }
                    } else if h.type == .clipboard {
                        self.clipboard?.handleClipboard(payload)
                    } else if h.type == .fileTransfer {
                        self.clipboard?.handleFile(payload)
                    }
                } catch {
                    // A connection closed by the write side (send timeout,
                    // client quit) surfaces here as EBADF/ECONNRESET; that is
                    // an ordinary disconnect, not something worth a log line.
                    if let e = error as? POSIXError,
                       e.code == .EBADF || e.code == .ECONNRESET || e.code == .ENOTCONN || e.code == .EPIPE {
                        log("session: client disconnected")
                    } else {
                        log("session: read loop ended: \(error)")
                    }
                    self.signalDisconnect()
                    break
                }
            }
        }
    }

    var isDisconnected: Bool {
        lockState.lock(); let v = disconnectedFlag; lockState.unlock(); return v
    }

    private func signalDisconnect() {
        lockState.lock()
        let first = !disconnectedFlag
        disconnectedFlag = true
        lockState.unlock()
        if first {
            log("session: client disconnected")
            releaseInjectedInput()
        }
    }

    /// A client that goes away mid-chord leaves the remote with the key or
    /// button still down (clicks then behave as drags, and a stuck ⌃ turns the
    /// next click into a right click). Release everything we may have posted.
    private func releaseInjectedInput() {
        injectLock.lock()
        defer { injectLock.unlock() }
        let point = lastMousePoint ?? CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        // Release the keys we actually pressed (either hand), not just the left
        // ones: a right ⌘ held at disconnect would stay down otherwise.
        let keys = heldModifiers.isEmpty ? Set<CGKeyCode>([55, 56, 58, 59]) : heldModifiers
        for code in keys {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { continue }
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
        heldModifiers.removeAll()
        injectedFlags = 0
        let ups: [(CGEventType, CGMouseButton)] = [
            (.leftMouseUp, .left), (.rightMouseUp, .right), (.otherMouseUp, .center),
        ]
        for (type, button) in ups {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
        }
    }

    /// System-UI actions: post the shortcut into the HID stream (no TCC needed).
    private func performRemote(_ action: RemoteAction) {
        log("command: \(action)")
        DispatchQueue.main.async {
            performRemoteAction(action)
        }
    }

    /// Modifier key codes and their bit in the flags word (both sides of the
    /// keyboard: left control and right control set the same bit).
    private static let modifierKeys: [(key: CGKeyCode, bit: UInt64)] = [
        (55, 0x100000), (54, 0x100000),  // command
        (56, 0x020000), (60, 0x020000),  // shift
        (58, 0x080000), (61, 0x080000),  // option
        (59, 0x040000), (62, 0x040000),  // control
    ]

    /// One key per bit, used when the client reports a bit we are not holding.
    private static let canonicalModifiers: [(key: CGKeyCode, bit: UInt64)] = [
        (55, 0x100000), (56, 0x020000), (58, 0x080000), (59, 0x040000),
    ]

    /// Which modifier keys we actually pressed on the remote. Tracking the key
    /// (not just the bit) is what lets a right-hand ⌃ be released by its own
    /// key up instead of being mistaken for the left one.
    private var heldModifiers = Set<CGKeyCode>()
    /// `inject()` runs on the reader thread, `releaseInjectedInput()` can be
    /// called from the send queue when a write fails; without this a release
    /// can be followed by a late key-down and leave the remote stuck.
    private let injectLock = NSLock()

    private func modifierBit(of key: CGKeyCode) -> UInt64 {
        Self.modifierKeys.first { $0.key == key }?.bit ?? 0
    }

    private func postModifier(_ key: CGKeyCode, down: Bool, flags: UInt64) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: flags)
        e.post(tap: .cghidEventTap)
    }

    /// Make the remote's held modifiers match the flags the client had when it
    /// sent this event. A plain left click must not arrive as a control-click
    /// (which macOS shows as a right click) just because a key-up went missing;
    /// the same sync makes ⌘-click and ⇧-click behave like they did locally.
    private func syncModifiers(to flags: UInt64) {
        let mask: UInt64 = 0x1F0000  // cmd/shift/caps/option/control
        let want = flags & mask
        for key in Array(heldModifiers) {
            let bit = modifierBit(of: key)
            if bit == 0 || want & bit == 0 {
                postModifier(key, down: false, flags: want)
                heldModifiers.remove(key)
            }
        }
        for (key, bit) in Self.canonicalModifiers where want & bit != 0 {
            if !heldModifiers.contains(where: { modifierBit(of: $0) == bit }) {
                postModifier(key, down: true, flags: want)
                heldModifiers.insert(key)
            }
        }
        injectedFlags = (injectedFlags & ~mask) | want
    }

    /// Record a modifier key we injected directly (flagsChanged/keyDown path).
    private func noteModifierKey(_ key: CGKeyCode, flags: UInt64) {
        let bit = modifierBit(of: key)
        guard bit != 0 else { return }
        if flags & bit != 0 { heldModifiers.insert(key) } else { heldModifiers.remove(key) }
    }

    private func inject(_ ev: InputEvent) {
        injectLock.lock()
        defer { injectLock.unlock() }
        let p = CGPoint(
            x: displayBounds.minX + ev.x * displayBounds.width,
            y: displayBounds.minY + ev.y * displayBounds.height
        )
        inputCount += 1
        lastMousePoint = p
        if ev.type == .keyDown || ev.type == .keyUp || ev.type == .flagsChanged { keyCount += 1 }
        if inputCount % 120 == 0 { log("input events=\(inputCount) keys=\(keyCount)") }

        switch ev.type {
        case .keyDown, .keyUp:
            syncModifiers(to: ev.flags)
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(ev.keyCode), keyDown: ev.type == .keyDown) else { return }
            e.flags = CGEventFlags(rawValue: ev.flags)
            if ev.isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            e.post(tap: .cghidEventTap)
        case .flagsChanged:
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(ev.keyCode), keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = CGEventFlags(rawValue: ev.flags)
            e.post(tap: .cghidEventTap)
            injectedFlags = ev.flags
            noteModifierKey(CGKeyCode(ev.keyCode), flags: ev.flags)
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            let type: CGEventType
            let button: CGMouseButton
            switch ev.type {
            case .mouseMoved: type = .mouseMoved; button = .left
            case .leftMouseDown: type = .leftMouseDown; button = .left
            case .leftMouseUp: type = .leftMouseUp; button = .left
            case .leftMouseDragged: type = .leftMouseDragged; button = .left
            case .rightMouseDown: type = .rightMouseDown; button = .right
            case .rightMouseUp: type = .rightMouseUp; button = .right
            case .rightMouseDragged: type = .rightMouseDragged; button = .right
            case .otherMouseDown: type = .otherMouseDown; button = .center
            case .otherMouseUp: type = .otherMouseUp; button = .center
            case .otherMouseDragged: type = .otherMouseDragged; button = .center
            default: return
            }
            syncModifiers(to: ev.flags)
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(ev.button))
            e.flags = CGEventFlags(rawValue: ev.flags)
            if ev.type != .mouseMoved && ev.type != .leftMouseDragged && ev.type != .rightMouseDragged && ev.type != .otherMouseDragged {
                // A double-click is two down/up pairs; the second pair must carry
                // click state 2 or the remote app sees two single clicks.
                e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, ev.clickCount)))
            }
            e.post(tap: .cghidEventTap)
        case .scroll:
            scrollCount += 1
            if scrollCount <= 10 { log("scroll \(scrollCount) phase=\(ev.phase) momentum=\(ev.momentum) dx=\(ev.scrollX) dy=\(ev.scrollY)") }
            let dy = Int32(max(-1_000_000, min(1_000_000, ev.scrollY)))
            let dx = Int32(max(-1_000_000, min(1_000_000, ev.scrollX)))
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(ev.phase))
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(ev.momentum))
            e.post(tap: .cghidEventTap)
        }
    }

    func stop() async {
        localMute?.stop()
        localMute = nil
        clipboard?.stop()
        clipboard = nil
        if let stream {
            try? await stream.stopCapture()
        }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        stream = nil
        session = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if audioEnabled, CMSampleBufferIsValid(sampleBuffer) { handleAudio(sampleBuffer) }
            return
        }
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        captured += 1
        feedTimes[Int64(pts.value)] = FeedStamp(host: now, wall: Int64(Date().timeIntervalSince1970 * 1_000_000))
        // Bound the map even if a frame never reaches the encoder callback: at
        // 60 fps an unbounded one is a slow leak for a session left open all day.
        if feedTimes.count > 600, let oldest = feedTimes.keys.min() {
            feedTimes.removeValue(forKey: oldest)
        }
        let shouldDump = dumpPath != nil && !dumped && captured == 30
        if shouldDump { dumped = true }
        lock.unlock()
        if shouldDump { dumpFrame(pb) }

        if inFlight.wait(timeout: .now()) == .timedOut {
            lock.lock(); dropped += 1; feedTimes.removeValue(forKey: Int64(pts.value)); lock.unlock()
            return
        }
        guard let session else {
            lock.lock(); feedTimes.removeValue(forKey: Int64(pts.value)); lock.unlock()
            return
        }
        lock.lock()
        let force = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let props: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb,
            presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
            frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
        if st != noErr {
            inFlight.signal()
            lock.lock(); dropped += 1; feedTimes.removeValue(forKey: Int64(pts.value)); lock.unlock()
        }
    }

    // MARK: audio

    /// ScreenCaptureKit hands back the display's audio in whatever format the
    /// system picked; convert once to the fixed wire format (48 kHz, 2 ch,
    /// int16 interleaved) so the client can schedule buffers untouched.
    private func handleAudio(_ sbuf: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sbuf),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt),
              let src = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sbuf))
        guard frames > 0 else { return }

        if audioSourceFormat != src {
            audioSourceFormat = src
            audioConverter = AVAudioConverter(from: src, to: audioTarget)
            lock.lock()
            let firstTime = !audioLoggedSource
            audioLoggedSource = true
            lock.unlock()
            if firstTime {
                log("audio source: \(Int(src.sampleRate)) Hz \(src.channelCount) ch interleaved=\(src.isInterleaved) float=\(src.commonFormat == .pcmFormatFloat32)")
            }
        }
        guard audioConverter != nil,
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sbuf, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList)
        guard copyStatus == noErr else { return }

        let capacity = AVAudioFrameCount(Double(frames) * audioTarget.sampleRate / src.sampleRate) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: audioTarget, frameCapacity: capacity) else { return }
        do { try audioConverter?.convert(to: outBuf, from: inBuf) } catch { return }

        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: n * 4)
        lock.lock()
        audioPackets += 1
        audioBytes += data.count
        let dead = closed
        lock.unlock()
        guard !dead else { return }
        let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        sendQueue.async { [weak self] in
            guard let self else { return }
            do { try self.connection.send(packet(type: .audio, ptsMicros: micros, payload: data)) }
            catch {
                self.lock.lock(); self.closed = true; self.lock.unlock()
                self.signalDisconnect()
            }
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
                    let f = StreamFormat(width: captureWidth, height: captureHeight, codec: codec,
                                      parameterSets: sets, color: colorMode)
                    sendQueue.async { [weak self] in
                        guard let self else { return }
                        do {
                            try self.connection.send(packet(type: .format, payload: f.encode()))
                            log("sent format \(self.captureWidth)x\(self.captureHeight) params=\(sets.count)")
                        } catch {
                            self.lock.lock(); self.closed = true; self.lock.unlock()
                            self.signalDisconnect()
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
                    bytes += length
                    if closed {
                        dropped += 1
                    } else {
                        pending += 1
                        queuedBytes += length
                        if pending > sendCap || queuedBytes > sendByteCap {
                            // Congested: drop this frame instead of letting the
                            // send queue grow. ProRes frames are independent;
                            // HEVC keyframes come every 60 frames, so dropping
                            // one costs ~1 s of artefacts and we ask the encoder
                            // for a fresh keyframe right away.
                            pending -= 1
                            queuedBytes -= length
                            dropped += 1
                            // Any dropped HEVC frame leaves a hole until the
                            // next IDR (~1 s of artefacts), so ask for one
                            // whether or not the dropped frame was a keyframe.
                            if codec == .hevc { forceKeyframe = true }
                        } else {
                            sendQueue.async { [weak self] in
                                guard let self else { return }
                                do {
                                    try self.connection.send(packet(type: .frame, flags: isKey ? 1 : 0, ptsMicros: micros, payload: data))
                                    self.lock.lock(); self.sent += 1; self.pending -= 1; self.queuedBytes -= length; self.lock.unlock()
                                } catch {
                                    self.lock.lock(); self.pending -= 1; self.queuedBytes -= length; self.closed = true; self.lock.unlock()
                                    self.signalDisconnect()
                                }
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
        let audioLine = audioEnabled ? String(format: " audio=%d pkts/%.1fMbps", audioPackets, elapsed > 0 ? Double(audioBytes) * 8 / elapsed / 1e6 : 0) : ""
        log(String(format: "stats captured=%d encoded=%d sent=%d dropped=%d key=%d fps=%.1f bitrate=%.1fMbps encLat=%.2fms", c, e, s, d, k, fps, mbps, lat) + audioLine)
        // A virtual display that came up "asleep" gets ~1-2 fps from
        // ScreenCaptureKit no matter what the remote is doing, which looks like
        // "app 自动降帧" but is a capture-side state. Say which state it is in.
        if fps < 10, let id = preferredDisplayID, id != 0 {
            let asleep = CGDisplayIsAsleep(id) != 0
            let active = CGDisplayIsActive(id) != 0
            log("capture throttle: display=\(id) active=\(active) asleep=\(asleep) frames=\(c)")
            if asleep { wakeDisplay() }
        }
        if lat > 12 { log("WARNING: encode latency \(String(format: "%.1f", lat))ms exceeds 12ms budget") }
        if e > 0 && Double(d) / Double(e + d) > 0.01 { log("WARNING: drop ratio exceeds 1%") }
    }
}
