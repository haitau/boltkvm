import Foundation
import CoreAudio

/// Opt-in device mute for the controlled Mac while a client listens to the
/// forwarded audio stream (`--local-mute`; off by default since 2026-10-28).
///
/// The default A-1 behaviour is to pause the current Now Playing app instead.
/// This class remains for users who explicitly want device-level silence.
///
/// ScreenCaptureKit taps app audio before it reaches the output device, so
/// muting the device does not silence what the client receives. We prefer the
/// hardware mute property and fall back to volume 0 on devices that do not
/// expose mute.
///
/// Every change is written to a small state file before it is applied. If the
/// helper is killed (the common crash path is `SIGKILL` while replacing the
/// binary), the next helper restores the saved state before muting again, so a
/// crash cannot leave the Mac silent forever.
final class AudioOutputMute: @unchecked Sendable {
    private struct MemberState: Codable {
        let uid: String
        /// Original mute/volume values. Both are restored even if the fallback
        /// path used only one of them, so a crash cannot leave a member silent.
        let mute: UInt32?
        let volume: Float32?
    }

    private struct State: Codable {
        let uid: String
        let usedMute: Bool
        let mute: UInt32
        let volume: Float32?
        /// The server that owns this mute. A second helper starting while the
        /// first is still alive must not restore the first one's mute.
        let pid: Int32?
        /// Set when `uid` is an aggregate device with no native mute/volume.
        /// Its physical subdevices are muted individually instead.
        let members: [MemberState]?

        init(uid: String, usedMute: Bool, mute: UInt32, volume: Float32?,
             pid: Int32?, members: [MemberState]? = nil) {
            self.uid = uid
            self.usedMute = usedMute
            self.mute = mute
            self.volume = volume
            self.pid = pid
            self.members = members
        }
    }

    private static let marker: URL = {
        if let path = ProcessInfo.processInfo.environment["BOLTKVM_MUTE_STATE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = support.appendingPathComponent("BoltKVM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mute-state.json")
    }()

    private let queue = DispatchQueue(label: "boltkvm.audio.mute")
    private var device = AudioDeviceID(0)
    private var saved: State?
    private var listener: AudioObjectPropertyListenerBlock?
    private var running = false

    init() {
        Self.restoreStaleState()
    }

    /// Called at server startup, before a client is accepted: if the previous
    /// helper was killed while it had muted the speakers, put them back now
    /// instead of waiting for the next client to connect.
    static func restoreStaleState() {
        guard let data = try? Data(contentsOf: marker),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        if let pid = state.pid, pid > 0, kill(pid, 0) == 0 {
            log("audio: mute marker is owned by live pid \(pid); leaving it alone")
            return
        }
        if let members = state.members, !members.isEmpty {
            for member in members { restoreMember(member) }
            log("audio: restored a stale local-mute marker for \(members.count) aggregate members")
        } else if let dev = device(forUID: state.uid) {
            if state.usedMute { _ = setUInt32(dev, muteAddress, state.mute) }
            if let volume = state.volume { _ = setVolume(dev, volume) }
            log("audio: restored a stale local-mute marker for \(deviceName(dev) ?? state.uid)")
        }
        try? FileManager.default.removeItem(at: marker)
    }

    @discardableResult
    func start() -> Bool {
        var muted = false
        queue.sync {
            guard !self.running else { return }
            self.running = true
            guard let dev = Self.defaultOutputDevice() else {
                log("audio: no default output device to mute; local output stays as is")
                return
            }
            muted = self.mute(dev)
            self.installListener()
        }
        return muted
    }

    func stop() {
        queue.sync {
            guard self.running else { return }
            self.running = false
            self.removeListener()
            self.restore()
            try? FileManager.default.removeItem(at: Self.marker)
        }
    }

    // MARK: - Mute / restore

    @discardableResult
    private func mute(_ dev: AudioDeviceID) -> Bool {
        guard let uid = Self.deviceUID(dev) else { return false }
        var muteAddress = Self.muteAddress
        let canMute = AudioObjectHasProperty(dev, &muteAddress)
        let mute = Self.readUInt32(dev, Self.muteAddress) ?? 0
        let volume = Self.readVolume(dev)
        if !(canMute && Self.isSettable(dev, Self.muteAddress)) && volume == nil {
            let name = Self.deviceName(dev) ?? uid
            let members = Self.aggregateMembers(dev)
            if !members.isEmpty {
                return self.muteAggregate(dev, uid: uid, name: name, members: members)
            }
            log("audio: output device \(name) has no mute or volume control; not muting")
            return false
        }
        let state = State(uid: uid, usedMute: canMute && Self.isSettable(dev, Self.muteAddress),
                          mute: mute, volume: volume, pid: getpid())
        self.device = dev
        self.saved = state
        guard self.writeMarker(state) else {
            // Without a marker a crash would leave the Mac silent forever.
            // Better to leave the local output alone than to risk that.
            log("audio: cannot write the mute-state marker; not muting local output")
            self.saved = nil
            return false
        }

        var ok = false
        if state.usedMute {
            ok = Self.setUInt32(dev, Self.muteAddress, 1)
        }
        if !ok, volume != nil {
            // Fall back to zero volume. Save the original first, already done.
            ok = Self.setVolume(dev, 0)
            if ok, let current = self.saved {
                self.saved = State(uid: current.uid, usedMute: false,
                                   mute: current.mute, volume: current.volume, pid: current.pid)
            }
        }
        if ok {
            log("audio: muted local output \(Self.deviceName(dev) ?? uid) while the client listens")
            return true
        }
        log("audio: could not mute local output; the remote stream is unaffected")
        self.saved = nil
        try? FileManager.default.removeItem(at: Self.marker)
        return false
    }

    /// Multi-Output/Aggregate devices created in Audio MIDI Setup usually have
    /// no mute or master volume of their own. Their physical subdevices do, so
    /// mute those individually. This is the common "Mac mini + BlackHole"
    /// setup: the aggregate has no controls, but the built-in speakers do.
    private func muteAggregate(_ dev: AudioDeviceID, uid: String,
                               name: String, members: [MemberState]) -> Bool {
        let state = State(uid: uid, usedMute: false, mute: 0, volume: nil,
                          pid: getpid(), members: members)
        guard self.writeMarker(state) else {
            log("audio: cannot write the mute-state marker; not muting local output")
            return false
        }
        var applied = 0
        for member in members {
            guard let sub = Self.device(forUID: member.uid) else { continue }
            if member.mute != nil, Self.setUInt32(sub, Self.muteAddress, 1) {
                applied += 1
                continue
            }
            if let volume = member.volume, Self.setVolume(sub, 0) {
                applied += 1
                log("audio: aggregate member \(Self.deviceName(sub) ?? member.uid) has no usable mute; set volume to zero (was \(volume))")
            }
        }
        guard applied > 0 else {
            log("audio: aggregate output \(name) has no muteable physical members; not muting")
            try? FileManager.default.removeItem(at: Self.marker)
            return false
        }
        self.device = dev
        self.saved = state
        if applied < members.count {
            log("audio: muted \(applied)/\(members.count) members of aggregate output \(name); some outputs may still play")
        } else {
            log("audio: muted local output \(name) via \(applied) aggregate members while the client listens")
        }
        return true
    }

    private func restore() {
        guard let state = saved else { return }
        saved = nil
        if let members = state.members, !members.isEmpty {
            for member in members { Self.restoreMember(member) }
            log("audio: restored local output \(state.uid) aggregate members")
            return
        }
        guard let dev = Self.device(forUID: state.uid) else {
            log("audio: original output device \(state.uid) is gone; cannot restore its volume")
            return
        }
        if state.usedMute {
            _ = Self.setUInt32(dev, Self.muteAddress, state.mute)
        }
        if let volume = state.volume {
            _ = Self.setVolume(dev, volume)
        }
        log("audio: restored local output \(Self.deviceName(dev) ?? state.uid)")
    }

    private static func restoreMember(_ member: MemberState) {
        guard let dev = device(forUID: member.uid) else { return }
        if let mute = member.mute { _ = setUInt32(dev, muteAddress, mute) }
        if let volume = member.volume { _ = setVolume(dev, volume) }
    }

    @discardableResult
    private func writeMarker(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try data.write(to: Self.marker, options: .atomic)
            return true
        } catch {
            log("audio: mute marker write failed: \(error)")
            return false
        }
    }

    // MARK: - Device changes

    private func installListener() {
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                // The old device may still exist; restore it before moving the
                // mute to the new default.
                self.restore()
                if let dev = Self.defaultOutputDevice() { self.mute(dev) }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr {
            listener = block
        } else {
            log("audio: cannot watch the default output device for mute (status \(status))")
        }
    }

    private func removeListener() {
        guard let listener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        self.listener = nil
    }

    /// Physical members of an aggregate device. Virtual devices are skipped:
    /// muting BlackHole would not silence a speaker and could break a loopback
    /// workflow that shares the aggregate.
    private static func aggregateMembers(_ dev: AudioDeviceID) -> [MemberState] {
        var result: [MemberState] = []
        for uid in aggregateSubDeviceUIDs(dev) {
            guard let sub = device(forUID: uid), !isVirtual(sub) else { continue }
            let hasMute = isSettable(sub, muteAddress)
            let volume = readVolume(sub)
            guard hasMute || volume != nil else { continue }
            result.append(MemberState(uid: uid,
                                      mute: hasMute ? readUInt32(sub, muteAddress) : nil,
                                      volume: volume))
        }
        return result
    }

    private static func aggregateSubDeviceUIDs(_ dev: AudioDeviceID) -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &address) else { return [] }
        var value: CFArray?
        var size = UInt32(MemoryLayout<CFArray?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(dev, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let value else { return [] }
        return value as? [String] ?? []
    }

    private static func isVirtual(_ dev: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeVirtual
    }

    /// Human-readable route for logs. The 2026-10-28 report could only say
    /// "default output"; when a user hears silence the device name, volume and
    /// mute state are the first things needed to tell a routing mistake from a
    /// playback defect.
    static func describeDefaultOutput() -> String {
        guard let dev = defaultOutputDevice() else { return "no default output" }
        let name = deviceName(dev) ?? "unknown"
        let uid = deviceUID(dev) ?? "?"
        let volume = readVolume(dev).map { String(format: "%.2f", $0) } ?? "n/a"
        let mute = readUInt32(dev, muteAddress).map(String.init) ?? "n/a"
        return "\(name) [uid=\(uid) volume=\(volume) mute=\(mute)]"
    }

    // MARK: - CoreAudio helpers

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func isSettable(_ dev: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(dev, &address, &settable) == noErr && settable.boolValue
    }

    private static func readUInt32(_ dev: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setUInt32(_ dev: AudioDeviceID, _ address: AudioObjectPropertyAddress, _ value: UInt32) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(dev, &address, 0, nil, size, &value) == noErr
    }

    private static func readVolume(_ dev: AudioDeviceID) -> Float32? {
        var address = volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value) == noErr { return value }
        // Some devices expose only per-channel volume.
        address.mElement = 1
        if AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value) == noErr { return value }
        return nil
    }

    private static func setVolume(_ dev: AudioDeviceID, _ target: Float32) -> Bool {
        var address = volumeAddress
        var value = target
        let size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectSetPropertyData(dev, &address, 0, nil, size, &value) == noErr { return true }
        var ok = true
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            address.mElement = element
            if AudioObjectSetPropertyData(dev, &address, 0, nil, size, &value) != noErr { ok = false }
        }
        return ok
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = defaultOutputAddress
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return nil }
        return dev
    }

    private static func deviceUID(_ dev: AudioDeviceID) -> String? {
        var address = uidAddress
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(dev, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (uid as String) : nil
    }

    private static func deviceName(_ dev: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(dev, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (name as String) : nil
    }

    private static func device(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return nil }
        return devices.first { self.deviceUID($0) == uid }
    }
}
