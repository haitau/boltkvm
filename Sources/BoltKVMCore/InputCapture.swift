import Foundation
import AppKit
import CoreGraphics
import Darwin

private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
    return capture.handle(type: type, event: event)
}

/// Captures local HID events and forwards them to the controlled Mac.
/// While active, all captured events are swallowed so the local Mac does not
/// also react (needed for ⌘Tab / ⌘Space / ⌃↑).
final class InputCapture {
    private let conn: TCPConnection
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = false
    private var sent = 0
    private var tapDisabled = 0
    private let statsLock = NSLock()
    private let displayBounds: CGRect
    private let tapLocation: CGEventTapLocation

    init(conn: TCPConnection, tapLocation: CGEventTapLocation = .cgSessionEventTap) {
        self.conn = conn
        self.tapLocation = tapLocation
        self.displayBounds = CGDisplayBounds(CGMainDisplayID())
    }

    func start() -> Bool {
        guard CGPreflightListenEventAccess() else {
            log("input: listen-event access not granted (Input Monitoring)")
            return false
        }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: tapLocation,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: refcon
        ) else {
            log("input: CGEvent.tapCreate failed (Accessibility?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        active = true
        CGDisplayHideCursor(CGMainDisplayID())
        log("input: capture started tap=\(tapLocation == .cghidEventTap ? "hid" : "session") bounds=\(displayBounds)")
        return true
    }

    var sentEvents: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return sent
    }

    var tapDisabledCount: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return tapDisabled
    }

    func stop() {
        guard active else { return }
        active = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        tap = nil
        source = nil
        CGDisplayShowCursor(CGMainDisplayID())
        log("input: capture stopped sent=\(sentEvents)")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Counted so a long run can tell "the system killed the tap"
            // (lock screen / secure input / slow callback) from "no input happened".
            statsLock.lock(); tapDisabled += 1; statsLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard active else { return Unmanaged.passUnretained(event) }

        // ⌃⌥⌘Q stops forwarding and quits the client.
        if type == .keyDown {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if key == 12,
               flags.contains(.maskControl),
               flags.contains(.maskAlternate),
               flags.contains(.maskCommand) {
                stop()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return nil
            }
        }

        let loc = event.location
        let nx = displayBounds.width > 0 ? min(1, max(0, (loc.x - displayBounds.minX) / displayBounds.width)) : 0
        let ny = displayBounds.height > 0 ? min(1, max(0, (loc.y - displayBounds.minY) / displayBounds.height)) : 0

        var ev: InputEvent?
        switch type {
        case .keyDown, .keyUp:
            let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let repeat_ = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            ev = InputEvent(type: type == .keyDown ? .keyDown : .keyUp,
                            keyCode: key, flags: event.flags.rawValue,
                            x: nx, y: ny, isRepeat: repeat_)
        case .flagsChanged:
            let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            ev = InputEvent(type: .flagsChanged, keyCode: key, flags: event.flags.rawValue, x: nx, y: ny)
        case .mouseMoved:
            ev = InputEvent(type: .mouseMoved, flags: event.flags.rawValue, x: nx, y: ny)
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            let map: [CGEventType: InputEventType] = [
                .leftMouseDown: .leftMouseDown, .leftMouseUp: .leftMouseUp, .leftMouseDragged: .leftMouseDragged,
                .rightMouseDown: .rightMouseDown, .rightMouseUp: .rightMouseUp, .rightMouseDragged: .rightMouseDragged,
                .otherMouseDown: .otherMouseDown, .otherMouseUp: .otherMouseUp, .otherMouseDragged: .otherMouseDragged,
            ]
            let button = UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber))
            ev = InputEvent(type: map[type] ?? .mouseMoved, flags: event.flags.rawValue,
                            x: nx, y: ny, button: button)
        case .scrollWheel:
            let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            let phase = UInt8(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventScrollPhase))
            let momentum = UInt8(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            ev = InputEvent(type: .scroll, flags: event.flags.rawValue, x: nx, y: ny,
                            scrollX: dx, scrollY: dy, phase: phase, momentum: momentum)
        default:
            return Unmanaged.passUnretained(event)
        }

        guard let ev else { return Unmanaged.passUnretained(event) }
        do {
            let pkt = packet(type: .input, ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000), payload: ev.encode())
            try conn.send(pkt)
            statsLock.lock(); sent += 1; statsLock.unlock()
        } catch {
            log("input: send failed: \(error)")
            stop()
        }
        return nil // swallow locally
    }
}
