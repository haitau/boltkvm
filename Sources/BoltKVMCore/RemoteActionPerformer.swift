import AppKit
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

private func keyViaSystemEvents(_ body: String) {
    let source = "tell application \"System Events\" to \(body)"
    guard let script = NSAppleScript(source: source) else { return }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error {
        log("command: AppleScript failed: \(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
    }
}
