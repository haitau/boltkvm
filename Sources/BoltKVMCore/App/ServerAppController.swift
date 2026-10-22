import AppKit
import Foundation
import ServiceManagement

/// Server role: no window, a menu bar item, and a supervised child process.
///
/// The capture/encode loop runs as the `boltkvm server` CLI bundled inside the
/// app, not in-process. Creating a CGVirtualDisplay from a GUI process turned out
/// to be unreliable (measured 2026-10-22: the same code succeeds from the CLI but
/// inside the app it was refused, or came up LoDPI at 3008x1692 instead of
/// 6016x3384). vdscreen hits the same wall and solves it the same way: a helper
/// owns the display, the app only supervises.
///
/// TCC follows the responsible process, so the Screen Recording grant on
/// BoltKVM.app covers the child.
final class ServerAppController: NSObject {
    private var statusItem: NSStatusItem?
    private var startStopItem: NSMenuItem?
    private var stateItem: NSMenuItem?
    private var detailItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    private var process: Process?
    private var pipe: Pipe?
    private var logHandle: FileHandle?
    private var wanted = false
    private var restartWork: DispatchWorkItem?
    private var lastStats = ""

    private var running: Bool { process?.isRunning == true }

    // MARK: - Lifecycle

    func startAutomatically() {
        installStatusItem()
        log("app: server role starting (screen recording granted: \(CGPreflightScreenCaptureAccess()))")
        guard CGPreflightScreenCaptureAccess() else {
            // A server has no window, so the permission lives in the menu bar
            // instead of a modal dialog that would block launch.
            setState("需要屏幕录制权限", detail: "点「授权…」")
            permissionItem?.isHidden = false
            return
        }
        permissionItem?.isHidden = true
        _ = AppKey.ensure()
        start()
    }

    func shutdown() {
        wanted = false
        restartWork?.cancel()
        stopProcess()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        permissionItem?.isHidden = true
        launch()
    }

    func stop() {
        wanted = false
        restartWork?.cancel()
        stopProcess()
        setState("已停止")
    }

    // MARK: - Menu

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

        let permission = NSMenuItem(title: "授权…（屏幕录制）", action: #selector(openPermissions), keyEquivalent: "")
        permission.target = self
        permission.isHidden = true
        menu.addItem(permission)
        permissionItem = permission

        let toggle = NSMenuItem(title: "启动服务", action: #selector(toggleService), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        startStopItem = toggle

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        updateLoginItem()

        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 BoltKVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func updateMenu() {
        startStopItem?.title = wanted ? "停止服务" : "启动服务"
        if let button = statusItem?.button {
            button.appearsDisabled = !running
        }
    }

    private func setState(_ text: String, detail: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateItem?.title = text
            if !detail.isEmpty { self.detailItem?.title = detail }
            self.updateMenu()
        }
    }

    // MARK: - Actions

    @objc private func toggleService() {
        wanted ? stop() : start()
    }

    @objc private func openPermissions() {
        _ = CGRequestScreenCaptureAccess()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item: \(error)")
            let alert = NSAlert()
            alert.messageText = "设置开机自启失败"
            alert.informativeText = "\(error.localizedDescription)\n\n用自签名证书签名后再试（./scripts/make-signing-identity.sh）。"
            alert.runModal()
        }
        updateLoginItem()
    }

    private func updateLoginItem() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.path))
    }

    // MARK: - Child process

    private var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/boltkvm-server").path
    }

    private var serverArguments: [String] {
        var args = ["server",
                    "--width", "3840",
                    "--height", "2160",
                    "--port", String(Prefs.serverPort),
                    "--virtual-display", "builtin",
                    "--virtual-display-size", Prefs.serverDisplaySize]
        if Prefs.serverCodec == "hevc" { args += ["--codec", "hevc"] }
        if Prefs.serverAudio { args += ["--audio"] }
        return args
    }

    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            setState("缺少采集子进程", detail: helperPath)
            log("app: helper missing at \(helperPath); rebuild with Packaging/build-app.sh")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        proc.arguments = serverArguments
        proc.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // Keep the child's output in the app log as well as parsing it: the menu
        // bar only has room for one line.
        if logHandle == nil {
            FileManager.default.createFile(atPath: AppLog.path, contents: nil)
            logHandle = FileHandle(forWritingAtPath: AppLog.path)
            logHandle?.seekToEndOfFile()
        }
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.logHandle?.write(data)
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") { self?.ingest(String(line)) }
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.handleExit(status: p.terminationStatus) }
        }

        do {
            try proc.run()
        } catch {
            setState("子进程启动失败", detail: error.localizedDescription)
            log("app: helper launch failed: \(error)")
            return
        }
        process = proc
        self.pipe = pipe
        setState("启动中…", detail: "端口 \(Prefs.serverPort)")
    }

    private func stopProcess() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }

    private func handleExit(status: Int32) {
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        updateMenu()
        guard wanted else { return }
        // The CLI relies on the supervisor loop; in the app role restarts are the
        // app's job. A small delay keeps a crash loop from spinning.
        setState("已退出，3 秒后重启", detail: "code \(status)")
        log("app: helper exited with \(status); restarting in 3s")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wanted else { return }
            self.launch()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func ingest(_ line: String) {
        guard !line.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if line.contains("listening on") {
                self.setState("监听中", detail: "端口 \(Prefs.serverPort)")
                self.lastStats = ""
            } else if line.contains("client connected") {
                self.setState("已连接", detail: "端口 \(Prefs.serverPort)")
            } else if line.contains("session ended") {
                self.setState("监听中", detail: self.lastStats.isEmpty ? "端口 \(Prefs.serverPort)" : self.lastStats)
            } else if let range = line.range(of: "fps=") {
                let fps = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
                if !fps.isEmpty {
                    self.lastStats = "\(fps) fps"
                    self.detailItem?.title = "\(fps) fps · 端口 \(Prefs.serverPort)"
                }
            } else if line.contains("virtual display: id=") {
                self.detailItem?.title = line.replacingOccurrences(of: "virtual display: ", with: "")
            }
        }
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
