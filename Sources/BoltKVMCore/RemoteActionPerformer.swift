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
private typealias MediaRemoteSendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

private let dockNotify: CoreDockSendNotificationFn? = {
    let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "CoreDockSendNotification") else {
        log("command: CoreDockSendNotification unavailable; falling back to key injection")
        return nil
    }
    return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
}()

/// MediaRemote's pause command (1) is app-agnostic: it reaches whatever app
/// currently owns Now Playing, including third-party players that do not expose
/// AppleScript. The framework is private, so resolve it at runtime and tolerate
/// its absence.
private let mediaRemotePause: MediaRemoteSendCommandFn? = {
    let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    guard let handle = dlopen(path, RTLD_NOW),
          let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
        log("media: MediaRemote unavailable; cannot pause the remote player")
        return nil
    }
    return unsafeBitCast(symbol, to: MediaRemoteSendCommandFn.self)
}()

@discardableResult
private func sendDockNotification(_ name: String, argument: Int32 = 0) -> Bool {
    guard let dockNotify else { return false }
    let status = dockNotify(name as CFString, argument)
    if status != 0 { log("command: \(name) \(argument) returned \(status)") }
    return status == 0
}

/// `com.apple.showdesktop.awake` is a *toggle*: call it twice and the windows
/// come back, which reads as "the button did the wrong thing". The Dock also
/// understands `com.apple.showdesktop.set` with an explicit 1/0, measured on
/// macOS 15: set 1 twice keeps the desktop shown, set 0 restores the windows.
private func setDesktopShown(_ shown: Bool) -> Bool {
    let flag: Int32 = shown ? 1 : 0
    guard sendDockNotification("com.apple.showdesktop.set", argument: flag) else { return false }
    log("command: showDesktop set \(flag) via dock notification")
    return true
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
        if setDesktopShown(true) { return }
        // Old Dock: fall back to the toggle, which at least shows the desktop
        // when it was not already shown.
        if sendDockNotification("com.apple.showdesktop.awake") {
            log("command: showDesktop via awake toggle")
            return
        }
        postShortcut(.showDesktop)
    case .hideDesktop:
        if setDesktopShown(false) { return }
        if sendDockNotification("com.apple.showdesktop.awake") {
            log("command: hideDesktop via awake toggle")
            return
        }
        log("command: hideDesktop unsupported on this Dock")
    case .spaceLeft:
        postShortcut(.spaceLeft)
    case .spaceRight:
        postShortcut(.spaceRight)
    case .pauseMedia:
        guard let mediaRemotePause else { return }
        // Pause is command 1; some players expose Stop (3) but not Pause.
        // Both satisfy "do not keep playing on a speaker nobody is using".
        var ok = mediaRemotePause(1, nil)
        if !ok { ok = mediaRemotePause(3, nil) }
        log(ok ? "media: paused the current Now Playing app" : "media: pause command was rejected")
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
