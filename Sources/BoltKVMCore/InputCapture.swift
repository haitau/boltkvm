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
/// Input writes never run on the caller's thread. An event that has to wait for
/// the socket is already stale, so a full backlog drops it instead of freezing
/// the main thread (a single `send` can block for up to 2 s on SO_SNDTIMEO).
/// Release packets bypass the cap: dropping one would strand a key or button
/// down on the remote.
final class InputSender {
    private let conn: TCPConnection
    private let queue = DispatchQueue(label: "boltkvm.input.send", qos: .userInteractive)
    private let lock = NSLock()
    private var backlog = 0
    private let maxBacklog = 64
    var onError: ((Error) -> Void)?

    init(conn: TCPConnection) { self.conn = conn }

    func send(_ pkt: Data, critical: Bool = false) {
        lock.lock()
        if !critical && backlog >= maxBacklog {
            lock.unlock()
            return
        }
        backlog += 1
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.backlog -= 1
                self.lock.unlock()
            }
            do { try self.conn.send(pkt) } catch { self.onError?(error) }
        }
    }
}

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
    private lazy var sender: InputSender = {
        let sender = InputSender(conn: conn)
        sender.onError = { [weak self] error in
            log("input: send failed: \(error)")
            DispatchQueue.main.async { self?.stop() }
        }
        return sender
    }()

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
        let pkt = packet(type: .input, ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000), payload: ev.encode())
        sender.send(pkt)
        statsLock.lock(); sent += 1; statsLock.unlock()
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
    private lazy var sender: InputSender = {
        let sender = InputSender(conn: conn)
        sender.onError = { [weak self] error in
            log("input: send failed: \(error)")
            DispatchQueue.main.async { self?.stop() }
        }
        return sender
    }()
    private weak var view: NSView?
    /// Aspect ratio of the picture (letterboxed inside the view); nil before the
    /// first frame arrives, in which case the whole view is used.
    var aspectProvider: (() -> CGFloat)?
    private var monitor: Any?
    private var sent = 0
    /// Key codes whose keyDown we forwarded (and therefore swallowed). The
    /// matching keyUp must only be swallowed if we swallowed the keyDown —
    /// otherwise the local system is left with a keyDown and no release, which
    /// repeats the character forever (seen 2026-10-22: a stuck "aaaaa").
    private var forwardedKeys = Set<UInt16>()
    /// Modifier key codes forwarded as down and not yet released remotely.
    private var forwardedModifiers = Set<UInt16>()
    /// Mouse buttons forwarded as down and not yet released remotely.
    private var forwardedButtons = Set<UInt8>()
    /// Last position sent, reused when a release has to be sent from outside
    /// the picture (where there is no meaningful new position).
    private var lastPoint: (x: Double, y: Double) = (0.5, 0.5)

    /// AppKit modifier bits, keyed by the key code that carries them. They are
    /// the same bits as `CGEventFlags`, which is what goes over the wire.
    private static let modifierFlag: [UInt16: UInt64] = [
        55: 0x100000,  // command
        56: 0x020000,  // shift
        57: 0x010000,  // caps lock
        58: 0x080000,  // option
        59: 0x040000,  // control
    ]

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
        releaseRemoteOnStop()
        forwardedKeys.removeAll()
        forwardedModifiers.removeAll()
        forwardedButtons.removeAll()
        log("input: window monitor stopped sent=\(sent)")
    }

    private func transmit(_ ev: InputEvent) {
        let pkt = packet(type: .input,
                         ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000),
                         payload: ev.encode())
        sender.send(pkt)
        sent += 1
        if sent % 60 == 0 { log("input: forwarded=\(sent)") }
    }

    /// Modifiers the local side has already released but the remote still holds
    /// (the release happened while the pointer was outside the picture).
    private func releaseStaleModifiers(flags: UInt64) {
        for code in forwardedModifiers {
            guard let bit = Self.modifierFlag[code], flags & bit == 0 else { continue }
            forwardedModifiers.remove(code)
            forwardedKeys.remove(code)
            transmit(InputEvent(type: .keyUp, keyCode: code, flags: flags,
                                x: lastPoint.x, y: lastPoint.y))
        }
    }

    /// Give the remote every key/button we forwarded and never released.
    private func releaseForwardedState(flags: UInt64) {
        guard !forwardedKeys.isEmpty || !forwardedButtons.isEmpty else { return }
        let keys = forwardedKeys
        let modifiers = forwardedModifiers
        let buttons = forwardedButtons
        forwardedKeys.removeAll()
        forwardedModifiers.removeAll()
        forwardedButtons.removeAll()
        for code in keys where !modifiers.contains(code) {
            transmit(InputEvent(type: .keyUp, keyCode: code, flags: flags,
                                x: lastPoint.x, y: lastPoint.y))
        }
        for code in modifiers {
            transmit(InputEvent(type: .keyUp, keyCode: code, flags: flags,
                                x: lastPoint.x, y: lastPoint.y))
        }
        for button in buttons {
            let type: InputEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            transmit(InputEvent(type: type, flags: flags, x: lastPoint.x, y: lastPoint.y, button: button))
        }
        log("input: released \(keys.count) key(s)/\(buttons.count) button(s) on leaving the picture")
    }

    /// Same release, best effort, when the session is torn down.
    private func releaseRemoteOnStop() {
        let flags: UInt64 = 0
        for code in forwardedKeys {
            sender.send(packet(type: .input, ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000),
                               payload: InputEvent(type: .keyUp, keyCode: code, flags: flags,
                                                   x: lastPoint.x, y: lastPoint.y).encode()), critical: true)
        }
        for button in forwardedButtons {
            let type: InputEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            sender.send(packet(type: .input, ptsMicros: Int64(Date().timeIntervalSince1970 * 1_000_000),
                               payload: InputEvent(type: type, flags: flags,
                                                   x: lastPoint.x, y: lastPoint.y, button: button).encode()), critical: true)
        }
    }

    private func fittedRect(in bounds: CGRect, aspect: CGFloat) -> CGRect {
        guard aspect > 0.01, bounds.width > 0, bounds.height > 0 else { return bounds }
        let viewAspect = bounds.width / bounds.height
        if viewAspect > aspect {
            let w = bounds.height * aspect
            return CGRect(x: bounds.midX - w / 2, y: bounds.minY, width: w, height: bounds.height)
        }
        let h = bounds.width / aspect
        return CGRect(x: bounds.minX, y: bounds.midY - h / 2, width: bounds.width, height: h)
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
        let point = view.convert(inWindow, from: nil)
        // The picture is centred with black bars, so map only inside the picture:
        // clicks on a bar belong to nobody and are passed through.
        let fit = fittedRect(in: view.bounds, aspect: aspectProvider?() ?? 0)
        let flags = UInt64(event.modifierFlags.rawValue)
        if !inVideo || !fit.contains(point) {
            // The pointer left the picture. Anything we forwarded and never saw
            // the release for stays down on the remote, and a stuck ⌃ turns the
            // next plain click into a control-click — i.e. a right click. Hand
            // everything back instead of dropping the release.
            releaseForwardedState(flags: flags)
            return event
        }
        var nx = Double((point.x - fit.minX) / max(1, fit.width))
        var ny = Double((point.y - fit.minY) / max(1, fit.height))
        if !view.isFlipped { ny = 1 - ny }
        nx = min(1, max(0, nx)); ny = min(1, max(0, ny))
        // A release that happened while the pointer was elsewhere never reached
        // the remote; correcting before this event keeps state in sync.
        releaseStaleModifiers(flags: flags)

        func send(_ ev: InputEvent) {
            var e = ev
            e.x = nx
            e.y = ny
            lastPoint = (nx, ny)
            transmit(e)
        }

        switch event.type {
        case .keyDown:
            forwardedKeys.insert(event.keyCode)
            if Self.modifierFlag[event.keyCode] != nil { forwardedModifiers.insert(event.keyCode) }
            send(InputEvent(type: .keyDown, keyCode: event.keyCode, flags: flags,
                            x: nx, y: ny, isRepeat: event.isARepeat))
        case .keyUp:
            // Only swallow the release of a key we actually captured.
            guard forwardedKeys.remove(event.keyCode) != nil else { return event }
            forwardedModifiers.remove(event.keyCode)
            send(InputEvent(type: .keyUp, keyCode: event.keyCode, flags: flags, x: nx, y: ny))
        case .flagsChanged:
            if let bit = Self.modifierFlag[event.keyCode], flags & bit != 0 {
                forwardedModifiers.insert(event.keyCode)
                forwardedKeys.insert(event.keyCode)
            } else {
                forwardedModifiers.remove(event.keyCode)
                forwardedKeys.remove(event.keyCode)
            }
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
                let button = UInt8(truncatingIfNeeded: event.buttonNumber)
                if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                    forwardedButtons.insert(button)
                } else {
                    forwardedButtons.remove(button)
                }
                send(InputEvent(type: t, flags: flags, x: nx, y: ny, button: button))
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
