import CoreGraphics
import CVirtualDisplay
import Foundation

/// How the virtual display comes into being.
enum VirtualDisplayMode: String {
    /// Someone else owns it (vdscreen's LaunchAgent, a plugged-in screen, ...).
    case external
    /// Created by this process through the vendored private-API glue.
    case builtin
}

/// A virtual display created in-process. Holding this object keeps the display
/// alive: the private API ties its lifetime to the creating process.
final class BuiltinVirtualDisplay {
    let displayID: CGDirectDisplayID
    let logicalWidth: Int
    let logicalHeight: Int
    let isHiDPI: Bool
    /// Fires on the main queue when the system takes the display away.
    var onLost: (() -> Void)?

    private var handle: OpaquePointer?

    init?(name: String, width: Int, height: Int, hiDPI: Bool) {
        guard let created = BKVVirtualDisplayCreate(name, Int32(width), Int32(height), hiDPI ? 1 : 0) else {
            return nil
        }
        handle = created
        displayID = BKVVirtualDisplayID(created)
        isHiDPI = BKVVirtualDisplayIsHiDPI(created) != 0
        logicalWidth = width
        logicalHeight = height
        BKVVirtualDisplaySetLostHandler(created, bkvDisplayLost, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Backing store actually in effect, read back from the system.
    func backingPixels() -> (width: Int, height: Int)? {
        guard let handle else { return nil }
        var w: Int32 = 0
        var h: Int32 = 0
        guard BKVVirtualDisplayBackingPixels(handle, &w, &h) != 0 else { return nil }
        return (Int(w), Int(h))
    }

    func stop() {
        guard let handle else { return }
        self.handle = nil          // clear first: destroy must not call back into us
        BKVVirtualDisplayDestroy(handle)
    }

    deinit { stop() }
}

/// C callback from the display's termination handler.
private func bkvDisplayLost(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let display = Unmanaged<BuiltinVirtualDisplay>.fromOpaque(context).takeUnretainedValue()
    display.onLost?()
}

/// Creates the display when asked to, and says nothing when it is external.
/// Must run on the main thread: the private API posts to the main queue and the
/// creation path pumps the main run loop while the system applies the mode.
@MainActor
func prepareVirtualDisplay(args: [String]) -> BuiltinVirtualDisplay? {
    let requested = argValue(args, "--virtual-display", "builtin")
    guard let mode = VirtualDisplayMode(rawValue: requested) else {
        log("unknown --virtual-display=\(requested); expected external or builtin")
        exit(2)
    }
    guard mode == .builtin else {
        log("virtual display: external (vdscreen or another source owns it)")
        return nil
    }

    let captureWidth = argInt(args, "--width", 3840)
    let captureHeight = argInt(args, "--height", 2160)
    let (logicalWidth, logicalHeight) = virtualDisplaySize(args, captureWidth: captureWidth, captureHeight: captureHeight)
    let hiDPI = !args.contains("--virtual-display-lodpi")

    let started = Date()
    var display = BuiltinVirtualDisplay(name: "boltKVM", width: logicalWidth, height: logicalHeight, hiDPI: hiDPI)
    if display == nil {
        // A display with this identity is usually still being torn down by the
        // previous helper. Give it a moment before giving up.
        // A display from the previous helper can linger (inactive, ASLEEP) for a
        // while after its owner dies; the system then refuses the same identity.
        // Falling back to the 1920x1080 placeholder here is wrong — the client
        // would stream the wrong screen — so keep trying for ~20 s.
        for attempt in 1...10 {
            Thread.sleep(forTimeInterval: 2)
            log("virtual display: creation refused, retry \(attempt)/10")
            display = BuiltinVirtualDisplay(name: "boltKVM", width: logicalWidth, height: logicalHeight, hiDPI: hiDPI)
            if display != nil { break }
        }
    }
    // Waking a freshly adopted or freshly created headless display: without user
    // activity it can sit ASLEEP, and a sleeping display produces no frames.
    wakeDisplay()
    guard let display else {
        // Do not fall back to the physical screen: the whole point of the
        // builtin display is that the operator's own desktop stays private.
        // Exiting hands the problem to the supervisor, which retries.
        log("virtual display: system refused \(logicalWidth)x\(logicalHeight) (logical) after 10 retries; exiting instead of streaming the local desktop")
        exit(3)
    }
    let took = String(format: "%.1fs", Date().timeIntervalSince(started))
    let backing = display.backingPixels().map { "\($0.width)x\($0.height)" } ?? "unknown"
    log("virtual display: id=\(display.displayID) logical=\(logicalWidth)x\(logicalHeight) backing=\(backing) hiDPI=\(display.isHiDPI) (\(took))")
    return display
}

/// Headless displays are power-managed like real ones: without an activity
/// declaration a freshly created display sits ASLEEP and WindowServer throttles
/// it (measured 2026-10-23: a recreated display captured at ~27 fps instead of
/// ~56 until the process restarted).
func wakeDisplay() {
    IOPMAssertionDeclareUserActivity("BoltKVM remote screen" as CFString, kIOPMUserActiveLocal, nil)
}

/// `--virtual-display-size WxH` sets the logical size; the default is half the
/// capture size, which makes the backing store match the capture exactly.
private func virtualDisplaySize(_ args: [String], captureWidth: Int, captureHeight: Int) -> (Int, Int) {
    let spec = argValue(args, "--virtual-display-size", "")
    if !spec.isEmpty {
        let parts = spec.lowercased().split(separator: "x")
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
            return (w, h)
        }
        log("bad --virtual-display-size=\(spec); expected WxH")
        exit(2)
    }
    return (max(640, captureWidth / 2), max(480, captureHeight / 2))
}
