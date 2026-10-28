import XCTest
import AVFoundation
@testable import BoltKVMCore

/// The 24-bit path is exercised without starting an output device: a
/// record-only AudioPlayer still runs each wire packet through the same
/// AudioPCM24 decoder/file writer used during playback.
final class Audio24Tests: XCTestCase {
    /// ScreenCaptureKit can deliver 44.1 kHz from USB/Bluetooth outputs. The
    /// simple AVAudioConverter overload throws -50 for sample-rate conversion;
    /// this guards the block-based path used by Server.handleAudio.
    func test44kTo48kConversionProducesFrames() throws {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                channels: 2, interleaved: false)!
        let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                channels: 2, interleaved: true)!
        let converter = try XCTUnwrap(AVAudioConverter(from: src, to: dst))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: src, frameCapacity: 1024))
        input.frameLength = 1024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 3072))
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .endOfStream; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        XCTAssertNotEqual(status, .error)
        XCTAssertGreaterThan(output.frameLength, 0)
    }

    func test24BitGraphBuildsWithoutPlayingAudio() throws {
        let player = AudioPlayer(play: true, recordPath: nil, wireFormat: .int24)
        guard player.isPlaybackActive else {
            throw XCTSkip("no usable output device for the int32 graph")
        }
        player.finish()
    }

    func test24BitPlaybackAcceptsSilentPackets() throws {
        let player = AudioPlayer(play: true, recordPath: nil, wireFormat: .int24)
        guard player.isPlaybackActive else {
            throw XCTSkip("no usable output device for the int32 graph")
        }
        let chunk = Data(repeating: 0, count: 480 * 6)
        for _ in 0..<10 { player.enqueue(chunk) }
        Thread.sleep(forTimeInterval: 0.05)
        player.finish()
    }

    func testPacked24BitSinkWritesFrames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boltkvm-audio24-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("capture.caf")

        let frames = 480
        let samples = (0..<(frames * 2)).map { i in Int32((i * 97) - 20_000) }
        let wire = samples.withUnsafeBufferPointer { AudioPCM24.pack($0) }

        let player = AudioPlayer(play: false, recordPath: url.path, wireFormat: .int24)
        XCTAssertEqual(player.bytesPerFrame, 6)
        player.enqueue(wire)
        player.finish()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, AVAudioFramePosition(frames))
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 32)
    }
}
