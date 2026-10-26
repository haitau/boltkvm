import XCTest
import CoreAudio
@testable import BoltKVMCore

/// Hardware regression for the Bluetooth-headphone case: the output route
/// changes, the old `AVAudioEngine` keeps accepting buffers without consuming
/// them, and the session goes silent until it is rebuilt.
///
/// This test really switches the Mac's default output device, so it is opt-in:
/// `BOLTKVM_AUDIO_ROUTE_TEST=1 swift test --filter AudioRouteChangeTests`.
/// On CI (one virtual device, no user listening) it skips.
final class AudioRouteChangeTests: XCTestCase {
    private let chunkFrames = 480  // 10 ms at 48 kHz

    func testRebuildsAfterDefaultOutputChanges() throws {
        guard ProcessInfo.processInfo.environment["BOLTKVM_AUDIO_ROUTE_TEST"] == "1" else {
            throw XCTSkip("set BOLTKVM_AUDIO_ROUTE_TEST=1 to switch the real output device")
        }
        let outputs = outputDevices()
        let original = defaultOutput()
        guard outputs.count >= 2, let other = alternativeOutput(excluding: original, in: outputs) else {
            throw XCTSkip("need at least two audio output devices")
        }
        addTeardownBlock { Self.setDefaultOutput(original) }

        let player = AudioPlayer(play: true, recordPath: nil)
        guard player.isPlaybackActive else {
            throw XCTSkip("no usable audio output device")
        }
        defer { player.finish() }

        feed(player, seconds: 0.8)
        let before = player.diagnostics
        XCTAssertEqual(before.starts, 1, "initial graph should start exactly once")
        XCTAssertTrue(before.active)

        XCTAssertTrue(Self.setDefaultOutput(other), "could not switch the default output")
        feed(player, seconds: 2.5)
        let switched = player.diagnostics
        XCTAssertTrue(switched.active, "playback was left inactive after the route change")
        XCTAssertGreaterThanOrEqual(switched.starts, 2,
                                    "route change did not rebuild the output graph")
        XCTAssertLessThan(switched.scheduled, 128,
                          "buffers are still queuing after the route change: output is not draining")

        XCTAssertTrue(Self.setDefaultOutput(original), "could not restore the original output")
        feed(player, seconds: 2.5)
        let restored = player.diagnostics
        XCTAssertTrue(restored.active)
        XCTAssertGreaterThanOrEqual(restored.starts, 3,
                                    "switching back did not rebuild the graph again")
        XCTAssertLessThan(restored.scheduled, 128,
                          "output did not drain after switching back")
    }

    /// Feed real-time-sized silent chunks from a background thread while this
    /// thread pumps the main run loop. AVAudioEngine delivers its configuration
    /// notification on the main queue; blocking the main thread here would hide
    /// that half of the fix and make the debounce look instantaneous.
    private func feed(_ player: AudioPlayer, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        let chunk = Data(repeating: 0, count: chunkFrames * AudioPlayer.bytesPerFrame)
        let feeder = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while Date() < end {
                player.enqueue(chunk)
                Thread.sleep(forTimeInterval: 0.01)
            }
            feeder.signal()
        }
        // An empty run loop can return immediately; this timer keeps it alive
        // until the feeder has produced its last chunk.
        let keepAlive = Timer(timeInterval: 1, repeats: true) { _ in }
        RunLoop.current.add(keepAlive, forMode: .common)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02)))
        }
        _ = feeder.wait(timeout: .now() + 1)
        keepAlive.invalidate()
    }

    // MARK: - CoreAudio helpers

    private func outputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput)
    }

    private func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    /// Prefer the built-in speakers over a virtual/aggregate device: they are
    /// always a real, independently startable output.
    private func alternativeOutput(excluding current: AudioDeviceID,
                                   in devices: [AudioDeviceID]) -> AudioDeviceID? {
        let candidates = devices.filter { $0 != current }
        return candidates.first(where: {
            let name = Self.deviceName($0)
            return name.contains("扬声器") || name.localizedCaseInsensitiveContains("speaker")
        }) ?? candidates.first
    }

    private func defaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    private static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value = id
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &value
            )
            if status != noErr { return false }
        }
        return true
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        return status == noErr ? (name as String) : ""
    }
}
