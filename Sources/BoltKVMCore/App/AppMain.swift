import AppKit
import Foundation
import ServiceManagement

/// Entry point for the app bundle. The CLI and the app share BoltKVMCore, so
/// everything below is wiring, not protocol code.
public enum AppMain {
    /// NSApplication.delegate is weak; keep the delegate alive here.
    private static var delegateStore: AppDelegate?

    public static func run() {
        // Scriptable login-item setup: TCC and SMAppService cannot be driven from
        // the CLI, but `--register-login-item` lets a deploy script flip it without
        // a human clicking through the menu bar.
        let args = CommandLine.arguments
        if args.contains("--register-login-item") || args.contains("--unregister-login-item") {
            let register = args.contains("--register-login-item")
            do {
                if register {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                print("login item \(register ? "registered" : "unregistered"); status=\(SMAppService.mainApp.status.rawValue)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("login item: \(error)\n".utf8))
                exit(1)
            }
        }
        // One instance per bundle: a second copy (login item + manual launch, or
        // a stale helper) would fight over the port. Server role has no window,
        // so the duplicate exits and just activates the running one.
        // Only the main executable counts: the capture helper lives inside the
        // bundle and reports the same bundle id, so matching on the id alone
        // would make the app refuse to start after an orphaned helper survives.
        // An flock, not just a bundle-id scan: login item + manual launch can
        // start two processes at the same instant, before either one shows up in
        // NSRunningApplication. The kernel lock is atomic, and it is released on
        // crash/SIGKILL, so a stale pid file never blocks a restart.
        if let owner = SingleInstance.acquire(.app) {
            if let id = Bundle.main.bundleIdentifier,
               let twin = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                   .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                twin.activate(options: [.activateAllWindows])
            }
            let note = "boltkvm: another instance is already running (pid \(owner)); exiting\n"
            // stderr already points at the app log, so also say it on stdout for
            // the case where someone launched the binary from a terminal.
            FileHandle.standardError.write(Data(note.utf8))
            FileHandle.standardOutput.write(Data(note.utf8))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegateStore = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var chooser: RoleChooserController?
    private var clientController: ClientController?
    private var serverController: ServerAppController?

    private var roleMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        if let role = Prefs.role {
            activate(role: role)
        } else {
            showChooser()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        clientController?.shutdown()
        serverController?.shutdown()
    }

    // MARK: - Roles

    private func showChooser() {
        let controller = RoleChooserController { [weak self] role in
            guard let self else { return }
            Prefs.role = role
            self.chooser?.close()
            self.chooser = nil
            self.activate(role: role)
        }
        chooser = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func activate(role: Role) {
        switch role {
        case .server:
            // No Dock icon, no window: a server is a background service.
            NSApp.setActivationPolicy(.accessory)
            let controller = ServerAppController()
            serverController = controller
            controller.startAutomatically()
        case .client:
            NSApp.setActivationPolicy(.regular)
            let controller = ClientController()
            clientController = controller
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        updateRoleMenu()
    }

    private func stopAll() {
        clientController?.shutdown()
        clientController = nil
        serverController?.shutdown()
        serverController = nil
    }

    /// Closing the client window used to leave no way back: this is a menu bar
    /// app, so there is no Dock icon to click.
    @objc private func showClientWindow() {
        guard Prefs.role == .client else { return }
        if clientController == nil {
            let controller = ClientController()
            clientController = controller
        }
        clientController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock/reopen events (also covers ⌘-tab back into the app).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showClientWindow() }
        return true
    }

    @objc private func switchRole() {
        stopAll()
        Prefs.role = nil
        NSApp.setActivationPolicy(.regular)
        showChooser()
    }

    @objc private func useServerRole() {
        guard Prefs.role != .server else { return }
        stopAll()
        Prefs.role = .server
        activate(role: .server)
    }

    @objc private func useClientRole() {
        guard Prefs.role != .client else { return }
        stopAll()
        Prefs.role = .client
        activate(role: .client)
    }

    @objc private func toggleFullScreen() {
        clientController?.toggleFullScreenAction(nil)
    }

    // MARK: - Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.t("menu.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("menu.role.server"), action: #selector(useServerRole), keyEquivalent: "")
        appMenu.addItem(withTitle: L.t("menu.role.client"), action: #selector(useClientRole), keyEquivalent: "")
        appMenu.addItem(withTitle: L.t("menu.role.switch"), action: #selector(switchRole), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.t("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in appMenu.items { item.target = item.action == #selector(NSApplication.terminate(_:))
            || item.action == #selector(NSApplication.hide(_:))
            || item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) ? nil : self }
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Own menu, after the app menu: the system auto-titles the first item with
        // the app name, so anything inserted before it steals that slot.
        let remoteItem = NSMenuItem(title: L.t("menu.remote"), action: nil, keyEquivalent: "")
        remoteItem.submenu = buildRemoteMenu()
        main.addItem(remoteItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L.t("menu.view"))
        let full = NSMenuItem(title: L.t("menu.fullscreen"), action: #selector(toggleFullScreen), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.control, .command]
        full.target = self
        viewMenu.addItem(full)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let roleItem = NSMenuItem()
        let menu = NSMenu(title: L.t("menu.role"))
        let showWindow = NSMenuItem(title: L.t("menu.showWindow"), action: #selector(showClientWindow), keyEquivalent: "")
        showWindow.target = self
        menu.addItem(showWindow)
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("menu.role.server"), action: #selector(useServerRole), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.role.client"), action: #selector(useClientRole), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.role.switch"), action: #selector(switchRole), keyEquivalent: "")
        for item in menu.items { item.target = self }
        roleItem.submenu = menu
        roleMenu = menu
        main.addItem(roleItem)

        NSApp.mainMenu = main
    }

    /// Actions that make the *remote* Mac do something, like Screen Sharing's
    /// control menu. They travel over the input channel, so no new protocol.
    private func buildRemoteMenu() -> NSMenu {
        let menu = NSMenu(title: L.t("menu.remote"))
        let entries: [String] = [
            "menu.remote.appWindows",
            "menu.remote.missionControl",
            "menu.remote.showDesktop",
        ]
        let actions: [Selector] = [#selector(remoteAppWindows),
                                   #selector(remoteMissionControl),
                                   #selector(remoteShowDesktop)]
        for (key, action) in zip(entries, actions) {
            let item = NSMenuItem(title: L.t(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func remoteMissionControl() { clientController?.showMissionControl() }
    @objc private func remoteAppWindows() { clientController?.showAppWindows() }
    @objc private func remoteShowDesktop() { clientController?.showDesktop() }

    private func updateRoleMenu() {
        guard let roleMenu else { return }
        for item in roleMenu.items {
            switch item.action {
            case #selector(useServerRole): item.state = Prefs.role == .server ? .on : .off
            case #selector(useClientRole): item.state = Prefs.role == .client ? .on : .off
            default: break
            }
        }
    }
}
