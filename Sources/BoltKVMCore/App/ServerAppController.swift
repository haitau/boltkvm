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
            setState(L.t("server.status.needsPermission"), detail: L.t("server.permission.hint"))
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
        reapOrphanHelpers()
        launch()
    }

    /// A helper outlives the app that spawned it if the app is killed outright
    /// (SIGKILL, crash). Left alone it keeps the port bound and the virtual
    /// display alive, so a fresh app would fail to bind. Reap them before launch.
    private func reapOrphanHelpers() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let current = process?.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != mine && app.processIdentifier != current
            && app.executableURL?.lastPathComponent == "boltkvm-server" {
            log("app: terminating orphan helper pid \(app.processIdentifier)")
            app.terminate()
        }
    }

    func stop() {
        wanted = false
        restartWork?.cancel()
        stopProcess()
        setState(L.t("server.status.stopped"))
    }

    // MARK: - Menu

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "BoltKVM")
            button.image?.isTemplate = true
            button.toolTip = L.t("server.tooltip")
        }
        let menu = NSMenu()

        stateItem = NSMenuItem(title: L.t("server.status.stopped"), action: nil, keyEquivalent: "")
        stateItem?.isEnabled = false
        menu.addItem(stateItem!)
        detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailItem?.isEnabled = false
        menu.addItem(detailItem!)
        menu.addItem(.separator())

        let permission = NSMenuItem(title: L.t("server.menu.permission"), action: #selector(openPermissions), keyEquivalent: "")
        permission.target = self
        permission.isHidden = true
        menu.addItem(permission)
        permissionItem = permission

        let toggle = NSMenuItem(title: L.t("server.menu.start"), action: #selector(toggleService), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        startStopItem = toggle

        let login = NSMenuItem(title: L.t("server.menu.login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        updateLoginItem()

        let logItem = NSMenuItem(title: L.t("server.menu.log"), action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L.t("server.menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func updateMenu() {
        startStopItem?.title = wanted ? L.t("server.menu.stop") : L.t("server.menu.start")
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
            alert.messageText = L.t("server.login.failed.title")
            alert.informativeText = L.f("server.login.failed.detail", error.localizedDescription)
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
            setState(L.t("server.helper.missing"), detail: helperPath)
            log("app: helper missing at \(helperPath); rebuild with Packaging/build-app.sh")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        proc.arguments = serverArguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        // Held open for the app's lifetime and never written: EOF tells the
        // helper we are gone, so it exits and releases the display.
        proc.standardInput = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["BOLTKVM_EXIT_ON_STDIN_EOF"] = "1"
        proc.environment = env
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
            setState(L.t("server.helper.failed"), detail: error.localizedDescription)
            log("app: helper launch failed: \(error)")
            return
        }
        process = proc
        self.pipe = pipe
        setState(L.t("server.status.starting"), detail: L.f("server.status.port", Prefs.serverPort))
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
        setState(L.t("server.status.restarting"), detail: "code \(status)")
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
                self.setState(L.t("server.status.listening"), detail: L.f("server.status.port", Prefs.serverPort))
                self.lastStats = ""
            } else if line.contains("client connected") {
                self.setState(L.t("server.status.connected"), detail: L.f("server.status.port", Prefs.serverPort))
            } else if line.contains("session ended") {
                self.setState(L.t("server.status.listening"), detail: self.lastStats.isEmpty ? L.f("server.status.port", Prefs.serverPort) : self.lastStats)
            } else if let range = line.range(of: "fps=") {
                let fps = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
                if !fps.isEmpty {
                    self.lastStats = L.f("server.status.stats", String(fps), Prefs.serverPort)
                    self.detailItem?.title = L.f("server.status.stats", String(fps), Prefs.serverPort)
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
