import Foundation
import AVFoundation
import CoreAudio
import CVirtualDisplay

/// Packed signed 24-bit PCM helpers shared by the server (Int32 capture buffer
/// to wire) and the client (wire to an AVAudioPCMBuffer). Samples are the
/// **top 24 bits** of the Int32 value, so a client can left-shift by 8 and get
/// an exact 32-bit container without losing the sign. Little-endian, like the
/// existing int16 format.
enum AudioPCM24 {
    static func pack(_ samples: UnsafeBufferPointer<Int32>) -> Data {
        var data = Data(count: samples.count * 3)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var o = 0
            for s in samples {
                let u = UInt32(bitPattern: s) >> 8
                p[o] = UInt8(u & 0xFF)
                p[o + 1] = UInt8((u >> 8) & 0xFF)
                p[o + 2] = UInt8((u >> 16) & 0xFF)
                o += 3
            }
        }
        return data
    }

    static func unpack(_ data: Data, into out: UnsafeMutablePointer<Int32>, count: Int) {
        guard data.count >= count * 3 else { return }
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var o = 0
            for i in 0..<count {
                let u = UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16)
                out[i] = Int32(bitPattern: u << 8)
                o += 3
            }
        }
    }
}

/// Client-side audio sink. Audio is opt-in: without `--audio` nothing is
/// created and the transport carries no audio packets at all, which keeps the
/// default "isolated" guarantee structural rather than a promise.
///
/// The wire format is negotiated: 48 kHz, 2 channels, either signed 16-bit
/// interleaved (the original) or packed signed 24-bit interleaved. The server
/// converts to the requested format before sending; a 24-bit stream is decoded
/// into float32 for the mixer, not into an int32 player connection.
///
/// Output-route changes (Bluetooth headphones leaving and coming back, a
/// display with speakers being plugged in, a sample-rate change) stop an
/// `AVAudioEngine` and silently detach the old player node from the new output.
/// Calling `start()` on that graph again is not enough: the engine reports
/// `isRunning == true`, the player still reports `isPlaying == true`, buffers
/// keep being accepted, and nothing is ever consumed. Every route change
/// therefore rebuilds the whole graph on a fresh engine. See
/// `docs/reports/2026-10-26-audio-route-and-fullscreen-chrome.md`.
final class AudioPlayer: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2
    static let int16BytesPerFrame = 4
    static let int24BytesPerFrame = 6

    let wireFormat: AudioWireFormat
    let bytesPerFrame: Int
    private let format: AVAudioFormat
    private let play: Bool
    private let recordPath: String?

    /// All AVAudioEngine/AVAudioPlayerNode lifecycle work, and every call to
    /// `scheduleBuffer`, runs here. A lock alone was not enough: a rebuild must
    /// not race a scheduling call on the receive thread.
    private let controlQueue = DispatchQueue(label: "boltkvm.audio.output", qos: .userInteractive)
    /// Route notifications must not wait behind a graph rebuild: a device switch
    /// that makes AVAudioEngine slow to start is exactly when the server needs
    /// the pause request most.
    private let routeQueue = DispatchQueue(label: "boltkvm.audio.route", qos: .utility)
    /// Mutated only on `controlQueue`; `playbackActive` mirrors it for callers.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var watchdog: DispatchSourceTimer?
    /// Only touched on `controlQueue`.
    private var retries = 0

    private var file: AVAudioFile?

    private var frames = 0
    private var bytes = 0
    private var sumSquares: Double = 0
    private var windowFrames = 0
    private var windowBytes = 0
    private var loggedWriteError = false
    private var windowSumSquares: Double = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    /// Guards every field touched by more than `controlQueue`: the receive
    /// thread, `controlQueue`, completion handlers and `finish` (which runs on
    /// close). No AVAudio call may run while it is held.
    private let lock = NSLock()
    private var scheduled = 0
    private var finished = false
    /// Incremented whenever the graph is replaced. Buffers scheduled against an
    /// older generation must not decrement the new graph's counter.
    private var generation = 0
    private var playbackActive = false
    private var starts = 0
    private var lastCompletion = DispatchTime.now().uptimeNanoseconds
    /// Incremented on the control queue for every route signal; only the last
    /// scheduled rebuild may run. This coalesces a Bluetooth switch's burst of
    /// notifications instead of starting a new graph for each one.
    private var rebuildToken = 0
    /// Client-side hook for A-2: the output device moved while audio is being
    /// played from the server, so the server should pause its player.
    var onOutputRouteChange: (() -> Void)?
    /// Fired immediately, before the graph rebuild, so the client can stop all
    /// local system audio while the output device is changing.
    var onOutputRouteChangeBegan: (() -> Void)?
    private var routeNotifyQueued = false
    private var routeBeganAt: UInt64 = 0
    /// More than ~2.5 s of queued audio means the output is not draining; older
    /// audio is worse than no audio (it drifts further behind every second).
    private let maxScheduled = 256

    init(play: Bool, recordPath: String?, wireFormat: AudioWireFormat = .int16) {
        self.play = play
        self.recordPath = recordPath
        self.wireFormat = wireFormat
        self.bytesPerFrame = wireFormat.bytesPerFrame
        // The mixer accepts float32 (and the old int16 graph); an int32
        // interleaved player connection fails with -10868 FormatNotSupported on
        // this macOS. Decode 24-bit wire samples into float32 for playback,
        // retaining the full 24-bit mantissa.
        self.format = wireFormat == .int16
            ? AVAudioFormat(commonFormat: .pcmFormatInt16,
                            sampleRate: AudioPlayer.sampleRate,
                            channels: AudioPlayer.channels,
                            interleaved: true)!
            : AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: AudioPlayer.sampleRate,
                            channels: AudioPlayer.channels,
                            interleaved: false)!

        if let path = recordPath {
            let url = URL(fileURLWithPath: path)
            // The 24-bit path plays through a float32 buffer, so record that
            // same format. Float32 carries the full 24-bit mantissa; the file
            // is diagnostic, not a second conversion step.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioPlayer.sampleRate,
                AVNumberOfChannelsKey: AudioPlayer.channels,
                AVLinearPCMBitDepthKey: wireFormat == .int16 ? 16 : 32,
                AVLinearPCMIsFloatKey: wireFormat == .int24,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            do {
                // processingFormat must match the buffers we hand to write(),
                // otherwise every write throws and the file stays header-only.
                file = try AVAudioFile(
                    forWriting: url, settings: settings,
                    commonFormat: wireFormat == .int16 ? .pcmFormatInt16 : .pcmFormatFloat32,
                    interleaved: wireFormat == .int16)
                log("audio: recording to \(path) (\(wireFormat == .int16 ? 16 : 24)-bit source)")
            } catch {
                log("audio: cannot open \(path) for writing: \(error)")
            }
        }

        if play {
            controlQueue.sync { self.buildGraph(reason: "initial") }
            listenForOutputDeviceChanges()
            startWatchdog()
        }
    }

    /// Whether the output engine is actually playing. False on a machine without
    /// an audio device (or one that refuses our format), so callers can tell
    /// "the user muted it" from "there is nothing to play to".
    var isPlaybackActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return playbackActive
    }

    /// Test/diagnostic snapshot. `starts` only counts successful graph builds, so
    /// a route-change test can prove the engine really was rebuilt instead of
    /// merely logging that it tried.
    struct Diagnostics {
        let active: Bool
        let scheduled: Int
        let generation: Int
        let starts: Int
    }

    var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(active: playbackActive, scheduled: scheduled,
                           generation: generation, starts: starts)
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Called for every `.audio` packet, in arrival order.
    ///
    /// `lock` guards counters only: no AVAudio call may run while it is held.
    /// `AVAudioPlayerNode.stop()` synchronously drains the completion queue, and
    /// our completion handler takes this lock — holding it across stop() is a
    /// guaranteed deadlock (it hung the app on window close).
    func enqueue(_ data: Data) {
        let count = data.count / bytesPerFrame
        guard count > 0 else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        bytes += data.count
        frames += count
        windowFrames += count
        windowBytes += data.count

        let fileSink = file
        // `playbackActive` is false while a rebuild is in flight: do not queue
        // audio for the graph that is being torn down.
        let shouldSchedule = play && playbackActive && scheduled < maxScheduled
        let scheduleGeneration = generation
        if shouldSchedule { scheduled += 1 }
        lock.unlock()

        var buf: AVAudioPCMBuffer?
        if fileSink != nil || shouldSchedule {
            buf = makeBuffer(data, frames: count)
        }

        if let fileSink, let buf {
            do { try fileSink.write(from: buf) } catch {
                lock.lock()
                let first = !loggedWriteError
                loggedWriteError = true
                lock.unlock()
                if first { log("audio: write failed: \(error)") }
            }
        }

        if shouldSchedule {
            if let buf {
                controlQueue.async { [weak self] in
                    self?.schedule(buf, generation: scheduleGeneration)
                }
            } else {
                // The buffer could not be allocated; give the permit back.
                lock.lock()
                if generation == scheduleGeneration { scheduled = max(0, scheduled - 1) }
                lock.unlock()
            }
        }

        // Track energy in the same 16-bit-equivalent scale for both formats,
        // so a silent capture is visible in the log without anyone listening.
        var acc = 0.0
        if wireFormat == .int16 {
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for s in samples {
                    let v = Double(s)
                    acc += v * v
                }
            }
        } else {
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                let samples = data.count / 3
                var o = 0
                for _ in 0..<samples {
                    let u = UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16)
                    let v = Double(Int32(bitPattern: u << 8)) / 65536.0
                    acc += v * v
                    o += 3
                }
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        sumSquares += acc
        windowSumSquares += acc
        let due = now - windowStart >= 60_000_000_000
        lock.unlock()
        if due { reportWindow(now: now) }
    }

    /// Runs on `controlQueue`.
    private func schedule(_ buf: AVAudioPCMBuffer, generation gen: Int) {
        lock.lock()
        let current = generation
        let active = playbackActive
        let done = finished
        lock.unlock()
        guard !done, active, current == gen, let player else { return }
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.generation == gen {
                self.scheduled = max(0, self.scheduled - 1)
                self.lastCompletion = DispatchTime.now().uptimeNanoseconds
            }
            self.lock.unlock()
        }
    }

    private func makeBuffer(_ data: Data, frames: Int) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        if wireFormat == .int16 {
            guard let dst = buf.int16ChannelData?[0] else { return nil }
            data.copyBytes(to: UnsafeMutableRawPointer(dst).assumingMemoryBound(to: UInt8.self),
                           count: frames * bytesPerFrame)
        } else {
            guard let dst = buf.floatChannelData else { return nil }
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var o = 0
                for i in 0..<(frames * 2) {
                    let u = UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16)
                    let sample = Int32(bitPattern: u << 8)
                    dst[i & 1][i >> 1] = Float(Double(sample) / 2_147_483_648.0)
                    o += 3
                }
            }
        }
        return buf
    }

    // MARK: - Output graph lifecycle

    /// Tear down the old graph and build a fresh one. Runs on `controlQueue`.
    ///
    /// A fresh `AVAudioEngine`/`AVAudioPlayerNode` pair, not just `start()`:
    /// after an output route change the old graph accepts buffers forever but
    /// consumes none (verified on this machine by switching the default output
    /// between Bluetooth and the built-in speakers).
    private func buildGraph(reason: String) {
        guard !isFinished else { return }

        let oldPlayer = player
        let oldEngine = engine
        player = nil
        engine = nil
        lock.lock()
        generation += 1
        scheduled = 0
        playbackActive = false
        lock.unlock()
        // Outside the lock: stop() drains the completion queue, which takes it.
        oldPlayer?.stop()
        oldEngine?.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // AVAudioEngine reports an unusable graph as an Objective-C exception
        // (-10868 FormatNotSupported and friends), not as a Swift error: on a
        // machine with no output device (headless Mac, VM, GitHub's macOS
        // runners) the connect below raises and kills the process. Build the
        // graph inside the ObjC catcher, so `--audio` there is silent instead of
        // fatal, and retry when a device appears later.
        var startError: Error?
        let built = BKVTryCatching {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { startError = error }
        }
        guard built, startError == nil else {
            let why = startError.map { "\($0)" } ?? "no usable output device"
            log("audio: playback unavailable (\(why)); will retry")
            scheduleRetry()
            return
        }

        player.play()
        self.engine = engine
        self.player = player
        lock.lock()
        let gen = generation
        playbackActive = true
        lastCompletion = DispatchTime.now().uptimeNanoseconds
        starts += 1
        let startNumber = starts
        lock.unlock()
        observe(engine, generation: gen)
        retries = 0
        log("audio: playing to default output (\(reason); graph #\(startNumber))")
    }

    /// A rebuild is requested by any signal that the output may have moved:
    /// AVAudioEngine's own notification, CoreAudio's default-output property, or
    /// the watchdog. Debounced so one device switch (several notifications a few
    /// milliseconds apart on Bluetooth) rebuilds once.
    private func requestRebuild(reason: String) {
        controlQueue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.rebuildToken += 1
            let token = self.rebuildToken
            // Wait for the route to be quiet. If another notification arrives,
            // the token changes and this build is skipped.
            self.controlQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.isFinished else { return }
                guard token == self.rebuildToken else { return }
                self.buildGraph(reason: reason)
            }
        }
    }

    private func observe(_ engine: AVAudioEngine, generation: Int) {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation
            let active = self.playbackActive
            self.lock.unlock()
            // A notification from the graph we already replaced must not tear
            // down the new one.
            guard active, current == generation else { return }
            self.handleOutputRouteSignal(reason: "output configuration changed", systemMute: false)
        }
    }

    /// CoreAudio tells us when the *system* default output changed, even if the
    /// engine's own notification is missed (or arrives while it still claims to
    /// be running). Bluetooth disconnect/reconnect shows up here.
    private func listenForOutputDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputRouteSignal(reason: "default output device changed", systemMute: true)
            self?.notifyOutputRouteChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block
        )
        guard status == noErr else {
            log("audio: cannot watch the default output device (status \(status))")
            return
        }
        outputListener = block
    }

    /// A route signal can arrive from CoreAudio before AVAudioEngine notices,
    /// and several times for one wired/Bluetooth switch. Stop the old graph
    /// immediately, tell the app to mute system output, then coalesce the
    /// rebuild. The later `onOutputRouteChange` is the deliberately delayed
    /// pause request; it is not the thing that stops local playback.
    private func handleOutputRouteSignal(reason: String, systemMute: Bool) {
        controlQueue.async { [weak self] in
            self?.suspendOnControlQueue()
        }
        // Only a real default-output change should mute the controller's whole
        // system output. An engine reconfiguration still stops our player, but
        // must not silence unrelated local apps.
        if systemMute {
            notifyRouteChangeBegan()
        }
        requestRebuild(reason: reason)
    }

    /// Runs on `controlQueue`. Stops the old graph immediately instead of
    /// waiting for the 150/450 ms rebuild timer, so audio does not keep playing
    /// into the device that is being unplugged. The old graph is discarded;
    /// buildGraph() will create a fresh one after the route settles.
    private func suspendOnControlQueue() {
        guard !isFinished else { return }
        let oldPlayer = player
        let oldEngine = engine
        player = nil
        engine = nil
        lock.lock()
        generation += 1
        scheduled = 0
        playbackActive = false
        lock.unlock()
        oldPlayer?.stop()
        oldEngine?.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func notifyRouteChangeBegan() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if finished || now &- routeBeganAt < 500_000_000 {
            lock.unlock()
            return
        }
        routeBeganAt = now
        let callback = onOutputRouteChangeBegan
        lock.unlock()
        callback?()
    }

    /// Debounced so one Bluetooth switch (several CoreAudio notifications) sends
    /// a single pause. The notification is deliberately tied to the default
    /// output listener, not the watchdog: a stalled graph is not a device change
    /// and must not stop the user's music.
    private func notifyOutputRouteChange() {
        lock.lock()
        if routeNotifyQueued || finished {
            lock.unlock()
            return
        }
        routeNotifyQueued = true
        lock.unlock()
        routeQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.routeNotifyQueued = false
            // The debounce can outlive the session; do not send a pause for a
            // connection that is already gone.
            let callback = self.finished ? nil : self.onOutputRouteChange
            self.lock.unlock()
            callback?()
        }
    }

    /// Two failure modes are covered here: an engine that stopped without a
    /// notification, and a player that accepts buffers but never consumes them
    /// (the exact Bluetooth-reconnect symptom). Both end in a graph rebuild.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.healthCheck() }
        timer.resume()
        watchdog = timer
    }

    /// Runs on `controlQueue`.
    private func healthCheck() {
        guard !isFinished else { return }
        // No graph at all: the retry timer owns recovery, so do not bypass its
        // backoff.
        guard let engine, let player else { return }
        if !engine.isRunning || !player.isPlaying {
            requestRebuild(reason: "engine stopped (running=\(engine.isRunning) playing=\(player.isPlaying))")
            return
        }
        lock.lock()
        let queued = scheduled
        let last = lastCompletion
        lock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        if queued >= maxScheduled && now &- last > 3_000_000_000 {
            requestRebuild(reason: "playback stalled with \(queued) buffers queued")
        }
    }

    private func scheduleRetry() {
        guard !isFinished else { return }
        retries += 1
        let delay = min(30.0, pow(2.0, Double(min(retries - 1, 5))))
        log("audio: retrying output in \(Int(delay))s")
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isFinished else { return }
            // A real device may have appeared and a notification may have
            // already rebuilt the graph; do not tear that one down.
            guard !self.isPlaybackActive else { return }
            self.buildGraph(reason: "retry #\(self.retries)")
        }
    }

    // MARK: - Reporting

    private func reportWindow(now: UInt64) {
        lock.lock()
        let secs = Double(now - windowStart) / 1e9
        let n = max(1, windowFrames)
        let rms = (windowSumSquares / Double(n)).squareRoot()
        let kbps = secs > 0 ? Double(windowBytes) * 8 / secs / 1e6 : 0
        let framesInWindow = windowFrames
        windowStart = now
        windowFrames = 0
        windowBytes = 0
        windowSumSquares = 0
        lock.unlock()
        let dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -120
        log(String(format: "audio.win frames=%d rms=%.1f dBFS mbps=%.2f", framesInWindow, dbfs, kbps))
    }

    func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()

        // The lock is not held across this sync: stop() drains the completion
        // queue, and every completion handler takes the lock.
        controlQueue.sync {
            self.watchdog?.cancel()
            self.watchdog = nil
            self.lock.lock()
            self.generation += 1
            self.scheduled = 0
            self.playbackActive = false
            self.lock.unlock()
            let player = self.player
            let engine = self.engine
            self.player = nil
            self.engine = nil
            player?.stop()
            engine?.stop()
            if let observer = self.observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let listener = self.outputListener {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, self.controlQueue, listener
                )
                self.outputListener = nil
            }
        }
        _ = file  // released here; AVAudioFile flushes to disk on deinit

        reportWindow(now: DispatchTime.now().uptimeNanoseconds)
        lock.lock()
        let frames = self.frames
        let bytes = self.bytes
        let rms = frames > 0 ? (sumSquares / Double(frames)).squareRoot() : 0
        let starts = self.starts
        lock.unlock()
        let dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -120
        let secs = Double(frames) / AudioPlayer.sampleRate
        log(String(format: "audio done frames=%d (%.1fs) rms=%.1f dBFS kb=%.0f graphs=%d format=%@",
                   frames, secs, dbfs, Double(bytes) / 1024, starts,
                   wireFormat == .int16 ? "int16" : "int24"))
    }
}
