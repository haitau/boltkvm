import XCTest
@testable import BoltKVMCore

/// Regression guard for the window-close hang: `finish()` used to hold the
/// audio lock while calling `AVAudioPlayerNode.stop()`, which synchronously
/// drains the completion queue — and that queue's handler takes the same lock.
/// The app froze on close with audio playing.
final class AudioFinishTests: XCTestCase {
    func testFinishReturnsWithQueuedBuffers() throws {
        let player = AudioPlayer(play: true, recordPath: nil)
        // GitHub's macOS runners have no audio output device, so the engine never
        // starts and there is no completion queue to drain — the deadlock this
        // guards cannot happen there. Skip instead of failing on missing hardware.
        guard player.isPlaybackActive else {
            throw XCTSkip("no usable audio output device; the drain path cannot be exercised")
        }
        // 1024 frames of silence, 32 times: enough to keep completion handlers
        // in flight when finish() runs.
        let chunk = Data(repeating: 0, count: 4 * 1024)
        for _ in 0..<32 { player.enqueue(chunk) }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            player.finish()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            XCTFail("finish() did not return within 5s: audio lock is held across AVAudioPlayerNode.stop()")
        }
    }
}
