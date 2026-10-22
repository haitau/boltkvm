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

/// Windowed client used by the app. A local NSEvent monitor sees events
/// delivered to our own window, so forwarding needs no Input Monitoring grant
/// (TCC applies to the global tap below, which is what the CLI client uses).
/// Coordinates are normalised inside the view, which is what the remote screen
/// is mapped onto.
final class WindowInputCapture {
    private let conn: TCPConnection
    private weak var view: NSView?
    private var monitor: Any?
    private var sent = 0
    /// Key codes whose keyDown we forwarded (and therefore swallowed). The
    /// matching keyUp must only be swallowed if we swallowed the keyDown —
    /// otherwise the local system is left with a keyDown and no release, which
    /// repeats the character forever (seen 2026-10-22: a stuck "aaaaa").
    private var forwardedKeys = Set<UInt16>()

    init(conn: TCPConnection, view: NSView) {
        self.conn = conn
        self.view = view
    }

    func start() -> Bool {
        guard view != nil else { return false }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            // Only the picture area belongs to the remote Mac. Everything else
            // (the connection bar, the window title, menu shortcuts) has to keep
            // working locally, so those events pass through untouched.
            return self.handle(event)
        }
        log("input: window monitor started (no TCC needed)")
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Release anything we may have left down, locally and on the remote.
        for code in forwardedKeys {
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)?
                .post(tap: .cghidEventTap)
        }
        if !forwardedKeys.isEmpty { log("input: released \(forwardedKeys.count) held key(s)") }
        forwardedKeys.removeAll()
        log("input: window monitor stopped sent=\(sent)")
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Escape hatch: ⌃⌥⌘Q always reaches the local Mac (disconnect + quit).
        if event.type == .keyDown,
           event.keyCode == 12,
           event.modifierFlags.contains([.control, .option, .command]) {
            stop()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }
        guard let view, let window = view.window else { return event }
        // Keyboard events carry no location, so "is the pointer over the picture"
        // decides whether the remote or the local app gets them.
        let inWindow: NSPoint
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        default:
            inWindow = event.locationInWindow
        }
        // Ask AppKit which view is under the pointer instead of converting
        // coordinates by hand (window/view origins made that error-prone).
        let hit = window.contentView?.hitTest(inWindow)
        let inVideo = hit === view || hit?.isDescendant(of: view) == true
        guard inVideo else { return event }
        let point = view.convert(inWindow, from: nil)
        let w = max(1, view.bounds.width), h = max(1, view.bounds.height)
        var nx = Double(point.x / w), ny = Double(point.y / h)
        if !view.isFlipped { ny = 1 - ny }
        nx = min(1, max(0, nx)); ny = min(1, max(0, ny))
        let flags = UInt64(event.modifierFlags.rawValue)

        func send(_ ev: InputEvent) {
            let pkt = packet(type: .input,
                             ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000),
                             payload: ev.encode())
            do {
                try conn.send(pkt)
                sent += 1
                if sent % 60 == 0 { log("input: forwarded=\(sent)") }
            } catch {
                log("input: send failed: \(error)")
                stop()
            }
        }

        switch event.type {
        case .keyDown:
            forwardedKeys.insert(event.keyCode)
            send(InputEvent(type: .keyDown, keyCode: event.keyCode, flags: flags,
                            x: nx, y: ny, isRepeat: event.isARepeat))
        case .keyUp:
            // Only swallow the release of a key we actually captured.
            guard forwardedKeys.remove(event.keyCode) != nil else { return event }
            send(InputEvent(type: .keyUp, keyCode: event.keyCode, flags: flags, x: nx, y: ny))
        case .flagsChanged:
            send(InputEvent(type: .flagsChanged, keyCode: event.keyCode, flags: flags, x: nx, y: ny))
        case .mouseMoved:
            send(InputEvent(type: .mouseMoved, flags: flags, x: nx, y: ny))
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            let map: [NSEvent.EventType: InputEventType] = [
                .leftMouseDown: .leftMouseDown, .leftMouseUp: .leftMouseUp, .leftMouseDragged: .leftMouseDragged,
                .rightMouseDown: .rightMouseDown, .rightMouseUp: .rightMouseUp, .rightMouseDragged: .rightMouseDragged,
                .otherMouseDown: .otherMouseDown, .otherMouseUp: .otherMouseUp, .otherMouseDragged: .otherMouseDragged,
            ]
            if let t = map[event.type] {
                send(InputEvent(type: t, flags: flags, x: nx, y: ny,
                                button: UInt8(truncatingIfNeeded: event.buttonNumber)))
            }
        case .scrollWheel:
            send(InputEvent(type: .scroll, flags: flags, x: nx, y: ny,
                            scrollX: Double(event.scrollingDeltaX),
                            scrollY: Double(event.scrollingDeltaY),
                            phase: UInt8(truncatingIfNeeded: event.phase.rawValue),
                            momentum: UInt8(truncatingIfNeeded: event.momentumPhase.rawValue)))
        default:
            break
        }
        // Swallow what we forwarded: the local Mac must not react to keys that
        // were meant for the remote one.
        return nil
    }
}
