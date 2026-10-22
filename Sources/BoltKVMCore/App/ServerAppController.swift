import AppKit
import Foundation

/// Server role: no window, a menu bar item, and a listener. The heavy lifting is
/// the same code the CLI runs — this only owns lifecycle and permissions.
final class ServerAppController: NSObject {
    private var statusItem: NSStatusItem?
    private var startStopItem: NSMenuItem?
    private var stateItem: NSMenuItem?
    private var detailItem: NSMenuItem?

    private var task: Task<Void, Never>?
    private var listener: TCPListener?
    private var virtualDisplay: BuiltinVirtualDisplay?
    private var server: Server?

    private var running: Bool { task != nil }

    func startAutomatically() {
        installStatusItem()
        guard CGPreflightScreenCaptureAccess() else {
            setState("等待屏幕录制权限")
            requestScreenRecording()
            return
        }
        _ = AppKey.ensure()
        start()
    }

    func shutdown() {
        stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "BoltKVM")
            button.image?.isTemplate = true
            button.toolTip = "BoltKVM 被控端"
        }
        let menu = NSMenu()
        stateItem = NSMenuItem(title: "已停止", action: nil, keyEquivalent: "")
        stateItem?.isEnabled = false
        menu.addItem(stateItem!)
        detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailItem?.isEnabled = false
        menu.addItem(detailItem!)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "启动服务", action: #selector(toggleService), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        startStopItem = toggle
        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 BoltKVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func updateMenu() {
        startStopItem?.title = running ? "停止服务" : "启动服务"
        if let button = statusItem?.button {
            button.appearsDisabled = !running
        }
    }

    private func setState(_ text: String, detail: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateItem?.title = text
            self.detailItem?.title = detail
            self.updateMenu()
        }
    }

    // MARK: - Lifecycle

    @objc private func toggleService() {
        running ? stop() : start()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.path))
    }

    private func requestScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "BoltKVM 靠 ScreenCaptureKit 抓取屏幕。请在系统设置的「隐私与安全性 → 屏幕录制」里勾选 BoltKVM，然后回到菜单栏重新启动服务。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard !running else { return }
        guard AppKey.ensure() else {
            setState("无法创建密钥文件")
            return
        }
        let port = UInt16(Prefs.serverPort)
        let displaySize = Prefs.serverDisplaySize
        // Creation must happen on the main thread; start() is reached from a menu
        // action, so this is that thread.
        let display = MainActor.assumeIsolated {
            prepareVirtualDisplay(args: ["server", "--virtual-display-size", displaySize])
        }
        if let display {
            display.onLost = { [weak self] in
                log("virtual display: removed by the system")
                DispatchQueue.main.async { self?.setState("虚拟屏被系统移除，正在重建…") }
                self?.stop()
                self?.start()
            }
        }
        virtualDisplay = display
        startListener(port: port)
    }

    private func startListener(port: UInt16) {
        setState("正在启动…", detail: "端口 \(port)")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let listener = try TCPListener(port: port, bind: "auto")
                self.listener = listener
                self.setState("监听中", detail: "\(listener.label):\(port)")
                while !Task.isCancelled {
                    let conn = try await acceptAsync(listener)
                    if Task.isCancelled { conn.close(); break }
                    log("client connected")
                    await self.handle(conn: conn)
                    if Task.isCancelled { break }
                }
            } catch {
                if !Task.isCancelled {
                    self.setState("启动失败", detail: error.localizedDescription)
                }
            }
        }
    }

    private func handle(conn: TCPConnection) async {
        guard let key = resolveAuthKey([]) else {
            log("no key file; refusing session")
            conn.close()
            return
        }
        do {
            try authenticateServer(conn: conn, key: key)
        } catch {
            log("auth failed: \(error)")
            conn.close()
            return
        }
        setState("已连接", detail: "\(Prefs.serverPort)")
        let server = Server(
            width: 3840,
            height: 2160,
            codec: Prefs.serverCodec == "hevc" ? .hevc : .prores422,
            connection: conn,
            dumpPath: nil,
            audioEnabled: Prefs.serverAudio,
            preferredDisplayID: virtualDisplay?.displayID
        )
        self.server = server
        do {
            try await server.start()
        } catch {
            log("session start failed: \(error)")
            conn.close()
            return
        }
        while !server.isDisconnected && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await server.stop()
        server.reportLine()
        conn.close()
        self.server = nil
        if !Task.isCancelled { setState("监听中", detail: "端口 \(Prefs.serverPort)") }
    }

    func stop() {
        task?.cancel()
        task = nil
        listener?.close()
        listener = nil
        server = nil
        virtualDisplay = nil
        setState("已停止")
    }
}

public enum AppLog {
    public static var path: String {
        let dir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/BoltKVM.log"
    }

    public static func redirect() {
        // A bundled app has nowhere to print to; send stderr to a file the menu
        // can open, and keep it from growing without bound.
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? nil, size > 5_000_000 {
            try? fm.removeItem(atPath: path)
        }
        freopen(path, "a", stderr)
    }
}
