import XCTest
import AVFoundation
@testable import BoltKVMCore

/// The 24-bit path is exercised without starting an output device: a
/// record-only AudioPlayer still runs each wire packet through the same
/// AudioPCM24 decoder/file writer used during playback.
final class Audio24Tests: XCTestCase {
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
