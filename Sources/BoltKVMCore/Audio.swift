import Foundation
import AVFoundation
import CVirtualDisplay

/// Client-side audio sink. Audio is opt-in: without `--audio` nothing is
/// created and the transport carries no audio packets at all, which keeps the
/// default "isolated" guarantee structural rather than a promise.
///
/// Wire format is fixed: 48 kHz, 2 channels, signed 16-bit, interleaved.
/// The server converts to this before sending, so the player can schedule
/// buffers with no further work.
final class AudioPlayer: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2
    static let bytesPerFrame = 4  // int16 * 2ch

    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: AudioPlayer.sampleRate,
                                       channels: AudioPlayer.channels,
                                       interleaved: true)!
    private let play: Bool
    private let recordPath: String?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var file: AVAudioFile?

    private var frames = 0
    private var bytes = 0
    private var sumSquares: Double = 0
    private var windowFrames = 0
    private var windowBytes = 0
    private var loggedWriteError = false
    private var windowSumSquares: Double = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    init(play: Bool, recordPath: String?) {
        self.play = play
        self.recordPath = recordPath

        if let path = recordPath {
            let url = URL(fileURLWithPath: path)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioPlayer.sampleRate,
                AVNumberOfChannelsKey: AudioPlayer.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            do {
                // processingFormat must match the buffers we hand to write(),
                // otherwise every write throws and the file stays header-only.
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
                log("audio: recording to \(path)")
            } catch {
                log("audio: cannot open \(path) for writing: \(error)")
            }
        }

        if play {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            // AVAudioEngine reports an unusable graph as an Objective-C exception
            // (-10868 FormatNotSupported and friends), not as a Swift error: on a
            // machine with no output device (headless Mac, VM, GitHub's macOS
            // runners) the host-app `connect` below raises and kills the process.
            // Build the graph inside the ObjC catcher, so `--audio` there is
            // silent instead of fatal.
            var startError: Error?
            let built = BKVTryCatching {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                do { try engine.start() } catch { startError = error }
            }
            guard built, startError == nil else {
                log("audio: playback unavailable (\(startError.map { "\($0)" } ?? "no usable output device")); audio disabled")
                return
            }
            player.play()
            self.engine = engine
            self.player = player
            log("audio: playing to default output")
            // Switching output device (headphones, display speakers, a session
            // change) stops the engine; without this the rest of the session is
            // silent.
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self, let engine = self.engine, let player = self.player else { return }
                guard !engine.isRunning else { return }
                do {
                    try engine.start()
                    player.play()
                    log("audio: restarted after an output configuration change")
                } catch {
                    log("audio: restart failed: \(error)")
                }
            }
        }
    }

    /// Whether the output engine actually came up. False on a machine without an
    /// audio device (or one that refuses our format), so callers can tell "the
    /// user muted it" from "there is nothing to play to".
    var isPlaybackActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return player != nil
    }

    /// Guards every field touched by both the receive thread and the main
    /// thread (`finish` runs on close), plus the in-flight buffer count.
    private let lock = NSLock()
    private var scheduled = 0
    private var finished = false
    /// More than ~5 s of queued audio means the output is not draining; older
    /// audio is worse than no audio (it drifts further behind every second).
    private let maxScheduled = 256

    /// Called for every `.audio` packet, in arrival order.
    ///
    /// `lock` guards counters only: no AVAudio call may run while it is held.
    /// `AVAudioPlayerNode.stop()` synchronously drains the completion queue, and
    /// our completion handler takes this lock — holding it across stop() is a
    /// guaranteed deadlock (it hung the app on window close).
    func enqueue(_ data: Data) {
        let count = data.count / AudioPlayer.bytesPerFrame
        guard count > 0 else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        bytes += data.count
        frames += count
        windowFrames += count
        windowBytes += data.count

        let fileSink = file
        let playerSink = player
        let shouldSchedule = playerSink != nil && scheduled < maxScheduled
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

        if shouldSchedule, let playerSink, let buf {
            playerSink.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.scheduled -= 1
                self.lock.unlock()
            }
        }

        // Track energy on the int16 samples so a silent capture is visible in
        // the log without anyone having to listen.
        var acc = 0.0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let v = Double(s)
                acc += v * v
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

    private func makeBuffer(_ data: Data, frames: Int) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        guard let dst = buf.int16ChannelData?[0] else { return nil }
        data.copyBytes(to: UnsafeMutableRawPointer(dst).assumingMemoryBound(to: UInt8.self),
                       count: frames * AudioPlayer.bytesPerFrame)
        return buf
    }

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
        let player = self.player
        let engine = self.engine
        let file = self.file
        self.player = nil
        self.engine = nil
        self.file = nil
        lock.unlock()

        // Outside the lock: stop() drains the completion queue, which takes it.
        player?.stop()
        engine?.stop()
        _ = file  // released here; AVAudioFile flushes to disk on deinit

        reportWindow(now: DispatchTime.now().uptimeNanoseconds)
        lock.lock()
        let frames = self.frames
        let bytes = self.bytes
        let rms = frames > 0 ? (sumSquares / Double(frames)).squareRoot() : 0
        lock.unlock()
        let dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -120
        let secs = Double(frames) / AudioPlayer.sampleRate
        log(String(format: "audio done frames=%d (%.1fs) rms=%.1f dBFS kb=%.0f",
                   frames, secs, dbfs, Double(bytes) / 1024))
    }
}
