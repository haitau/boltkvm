import AppKit
import Carbon
import Foundation

/// Executes the remote system-UI actions (App Exposé, Mission Control, Show
/// Desktop, Space switching).
///
/// macOS ignores synthetic CGEvents for its own system hotkeys, so the server
/// has to ask the system instead: Mission Control has a launchable app, the rest
/// go through System Events, which is a trusted sender.
///
/// This runs in whichever process owns the TCC identity. The helper is a bare
/// executable whose Automation requests are denied with -1743, so under the app
/// role it relays the action to the app (`@@REMOTE:<raw>`) and the app calls
/// this function instead.
func performRemoteAction(_ action: RemoteAction) {
    // The app is a background accessory in the server role, so asking System
    // Events out of the blue is denied without ever showing a dialog (and
    // without the app appearing under 隐私与安全性 → 自动化). This is the API
    // that actually raises the consent prompt; afterwards the app shows up in
    // that pane.
    if action != .missionControl {
        let status = requestAutomationPermission()
        if status != noErr {
            log("command: automation permission not granted (OSStatus \(status))")
        }
    }
    switch action {
    case .missionControl:
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    case .showDesktop:
        keyViaSystemEvents("key code 103")
    case .appWindows:
        keyViaSystemEvents("key code 125 using control down")
    case .spaceLeft:
        keyViaSystemEvents("key code 123 using control down")
    case .spaceRight:
        keyViaSystemEvents("key code 124 using control down")
    }
}

/// Asks TCC for the right to drive System Events, prompting if undecided.
@discardableResult
private func requestAutomationPermission() -> OSStatus {
    guard var target = systemEventsTarget() else { return OSStatus(-1) }
    return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                AEEventID(typeWildCard), true)
}

private func systemEventsTarget() -> AEAddressDesc? {
    var desc = AEAddressDesc()
    var bundleID = "com.apple.systemevents"
    let status = bundleID.withUTF8 { buf -> OSStatus in
        guard let base = buf.baseAddress else { return OSStatus(-1) }
        return OSStatus(AECreateDesc(DescType(typeApplicationBundleID), base, buf.count, &desc))
    }
    return status == noErr ? desc : nil
}

private func keyViaSystemEvents(_ body: String) {
    let source = "tell application \"System Events\" to \(body)"
    guard let script = NSAppleScript(source: source) else { return }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error {
        log("command: AppleScript failed: \(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
    }
}
