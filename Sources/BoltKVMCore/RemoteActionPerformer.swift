import CoreGraphics
import Foundation

/// Executes the remote system-UI actions (Mission Control, App Exposé, Show
/// Desktop, Space switching).
///
/// macOS ignores synthetic CGEvents for these system shortcuts — measured: ⌃↑
/// posted into the HID stream leaves the frame rate at 57 fps, i.e. nothing
/// happens — and AppleScript needed Automation permission that macOS never even
/// prompts a background accessory app for (-1743, no entry under 自动化).
///
/// What works is the Dock's own notification channel: `CoreDockSendNotification`
/// from HIServices. It is a private symbol, so it is resolved with dlsym and its
/// absence is tolerated (logged, then the key-injection fallback runs).
private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Int32

private let dockNotify: CoreDockSendNotificationFn? = {
    let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "CoreDockSendNotification") else {
        log("command: CoreDockSendNotification unavailable; falling back to key injection")
        return nil
    }
    return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
}()

@discardableResult
private func sendDockNotification(_ name: String) -> Bool {
    guard let dockNotify else { return false }
    let status = dockNotify(name as CFString, 0)
    if status != 0 { log("command: \(name) returned \(status)") }
    return status == 0
}

func performRemoteAction(_ action: RemoteAction) {
    switch action {
    case .missionControl:
        if sendDockNotification("com.apple.expose.awake") {
            log("command: missionControl via dock notification")
            return
        }
        postShortcut(.missionControl)
    case .appWindows:
        if sendDockNotification("com.apple.expose.front.awake") {
            log("command: appWindows via dock notification")
            return
        }
        postShortcut(.appWindows)
    case .showDesktop:
        if sendDockNotification("com.apple.showdesktop.awake") {
            log("command: showDesktop via dock notification")
            return
        }
        postShortcut(.showDesktop)
    case .spaceLeft:
        postShortcut(.spaceLeft)
    case .spaceRight:
        postShortcut(.spaceRight)
    }
}

private enum Shortcut {
    case missionControl, showDesktop, appWindows, spaceLeft, spaceRight

    var key: CGKeyCode {
        switch self {
        case .missionControl: return 126   // ↑
        case .appWindows: return 125       // ↓
        case .showDesktop: return 103      // F11
        case .spaceLeft: return 123        // ←
        case .spaceRight: return 124       // →
        }
    }

    var name: String {
        switch self {
        case .missionControl: return "missionControl ⌃↑"
        case .appWindows: return "appWindows ⌃↓"
        case .showDesktop: return "showDesktop F11"
        case .spaceLeft: return "spaceLeft ⌃←"
        case .spaceRight: return "spaceRight ⌃→"
        }
    }

    var withControl: Bool { self != .showDesktop }
}

private let controlKey: CGKeyCode = 59

private func postShortcut(_ shortcut: Shortcut) {
    let source = CGEventSource(stateID: .hidSystemState)

    if shortcut.withControl, let down = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: true) {
        down.flags = .maskControl
        down.post(tap: .cghidEventTap)
    }

    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: true),
       let keyUp = CGEvent(keyboardEventSource: source, virtualKey: shortcut.key, keyDown: false) {
        let flags: CGEventFlags = shortcut.withControl ? .maskControl : []
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        usleep(40_000)
        keyUp.post(tap: .cghidEventTap)
    }

    if shortcut.withControl, let up = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: false) {
        up.flags = []
        up.post(tap: .cghidEventTap)
    }

    log("command: posted \(shortcut.name)")
}
