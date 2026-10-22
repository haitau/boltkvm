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
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [])
            FileHandle.standardError.write(Data("another BoltKVM is already running (pid \(other.processIdentifier)); exiting\n".utf8))
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
        appMenu.addItem(withTitle: "关于 BoltKVM",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "作为被控端运行", action: #selector(useServerRole), keyEquivalent: "")
        appMenu.addItem(withTitle: "作为主控端运行", action: #selector(useClientRole), keyEquivalent: "")
        appMenu.addItem(withTitle: "重新选择角色…", action: #selector(switchRole), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoltKVM", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 BoltKVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in appMenu.items { item.target = item.action == #selector(NSApplication.terminate(_:))
            || item.action == #selector(NSApplication.hide(_:))
            || item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) ? nil : self }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        let full = NSMenuItem(title: "全屏", action: #selector(toggleFullScreen), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.control, .command]
        full.target = self
        viewMenu.addItem(full)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let roleItem = NSMenuItem()
        let menu = NSMenu(title: "角色")
        menu.addItem(withTitle: "作为被控端运行", action: #selector(useServerRole), keyEquivalent: "")
        menu.addItem(withTitle: "作为主控端运行", action: #selector(useClientRole), keyEquivalent: "")
        menu.addItem(withTitle: "重新选择角色…", action: #selector(switchRole), keyEquivalent: "")
        for item in menu.items { item.target = self }
        roleItem.submenu = menu
        roleMenu = menu
        main.addItem(roleItem)

        NSApp.mainMenu = main
    }

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
