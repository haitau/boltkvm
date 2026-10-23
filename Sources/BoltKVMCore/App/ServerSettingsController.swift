import AppKit

/// The 被控端 panel: what you get when you switch this Mac to server role.
///
/// Switching used to be silent — no window, and if Screen Recording had not been
/// granted the only hint was a menu-bar item nobody was looking at. This panel is
/// the visible landing place, and it carries the initial configuration
/// (resolution / quality / port) the user asked for.
final class ServerSettingsController: NSWindowController {
    private weak var server: ServerAppController?

    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let permissionButton = NSButton(title: L.t("server.panel.openSettings"),
                                            target: nil, action: nil)
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let portField = NSTextField(string: "")
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let rotateButton = NSButton(title: L.t("server.panel.rotate"),
                                        target: nil, action: nil)
    private let hintLabel = NSTextField(wrappingLabelWithString: L.t("server.panel.hint"))

    init(server: ServerAppController) {
        self.server = server
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = L.t("server.panel.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: L.t("server.panel.heading"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 352, width: 300, height: 22)
        content.addSubview(title)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.frame = NSRect(x: 24, y: 320, width: 10, height: 10)
        content.addSubview(statusDot)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.frame = NSRect(x: 42, y: 314, width: 410, height: 20)
        content.addSubview(statusLabel)

        permissionButton.target = self
        permissionButton.action = #selector(openPrivacySettings)
        permissionButton.bezelStyle = .rounded
        permissionButton.frame = NSRect(x: 24, y: 284, width: 200, height: 24)
        permissionButton.isHidden = true
        content.addSubview(permissionButton)

        let resolutionLabel = NSTextField(labelWithString: L.t("server.menu.resolution"))
        resolutionLabel.alignment = .right
        resolutionLabel.frame = NSRect(x: 24, y: 246, width: 80, height: 20)
        content.addSubview(resolutionLabel)

        resolutionPopup.frame = NSRect(x: 110, y: 242, width: 240, height: 26)
        resolutionPopup.target = self
        resolutionPopup.action = #selector(settingsChanged)
        content.addSubview(resolutionPopup)

        let customButton = NSButton(title: L.t("server.panel.custom"), target: self,
                                    action: #selector(addCustomResolution))
        customButton.bezelStyle = .rounded
        customButton.frame = NSRect(x: 356, y: 242, width: 90, height: 26)
        content.addSubview(customButton)

        let qualityLabel = NSTextField(labelWithString: L.t("server.menu.quality"))
        qualityLabel.alignment = .right
        qualityLabel.frame = NSRect(x: 24, y: 206, width: 80, height: 20)
        content.addSubview(qualityLabel)

        qualityPopup.frame = NSRect(x: 110, y: 202, width: 240, height: 26)
        qualityPopup.addItems(withTitles: [L.t("server.menu.quality.standard"),
                                           L.t("server.menu.quality.pixel")])
        qualityPopup.target = self
        qualityPopup.action = #selector(settingsChanged)
        content.addSubview(qualityPopup)

        let portLabel = NSTextField(labelWithString: L.t("server.panel.port"))
        portLabel.alignment = .right
        portLabel.frame = NSRect(x: 24, y: 166, width: 80, height: 20)
        content.addSubview(portLabel)

        portField.frame = NSRect(x: 110, y: 162, width: 100, height: 24)
        portField.target = self
        portField.action = #selector(settingsChanged)
        content.addSubview(portField)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 24, y: 84, width: 430, height: 64)
        content.addSubview(hintLabel)

        toggleButton.bezelStyle = .rounded
        toggleButton.keyEquivalent = "\r"
        toggleButton.target = self
        toggleButton.action = #selector(toggleService)
        toggleButton.frame = NSRect(x: 24, y: 24, width: 140, height: 30)
        content.addSubview(toggleButton)

        rotateButton.bezelStyle = .rounded
        rotateButton.target = self
        rotateButton.action = #selector(rotatePassword)
        rotateButton.frame = NSRect(x: 180, y: 24, width: 120, height: 30)
        content.addSubview(rotateButton)

        let close = NSButton(title: L.t("server.panel.close"), target: self, action: #selector(closePanel))
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 356, y: 24, width: 100, height: 30)
        content.addSubview(close)
    }

    /// Rotation breaks every stored client key, so it is confirmed first and then
    /// the helper restarts with the new file (clients get `auth failed` until they
    /// are given the new password).
    @objc private func rotatePassword() {
        let alert = NSAlert()
        alert.messageText = L.t("server.panel.rotate.confirm.title")
        alert.informativeText = L.t("server.panel.rotate.confirm.body")
        alert.addButton(withTitle: L.t("server.panel.rotate"))
        alert.addButton(withTitle: L.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let password = try PSK.writeNewPassword()
            log("app: rotated connection password")
            server?.restartForSettings()
            reload()
            let done = NSAlert()
            done.messageText = L.f("server.panel.rotate.done", password)
            done.addButton(withTitle: L.t("common.ok"))
            done.runModal()
        } catch {
            let failed = NSAlert()
            failed.messageText = L.f("server.panel.rotate.failed", error.localizedDescription)
            failed.addButton(withTitle: L.t("common.ok"))
            failed.runModal()
        }
    }

    /// Called by the controller on every state change.
    func updateStatus(_ text: String, connected: Bool, needsPermission: Bool) {
        statusLabel.stringValue = text
        permissionButton.isHidden = !needsPermission
        let color: NSColor = needsPermission ? .systemOrange : (connected ? .systemGreen : .secondaryLabelColor)
        statusDot.layer?.backgroundColor = color.cgColor
        toggleButton.title = server?.wantedState == true
            ? L.t("server.menu.stop")
            : L.t("server.menu.start")
    }

    func reload() {
        // The PSK is the one setting you cannot set here (both ends must hold the
        // same bytes), so at least show which key this machine will accept:
        // matching fingerprints on both ends is the whole "sync" story.
        var hint = L.t("server.panel.hint")
        if let key = resolveAuthKey([]) {
            if let stored = PSK.storedText(), PSK.isGeneratedPassword(stored) {
                hint += "\n" + L.f("server.panel.password", stored)
            }
            hint += "  " + L.f("server.panel.fingerprint", PSK.fingerprint(key))
        } else {
            hint += "\n" + L.t("server.panel.nokey")
        }
        hintLabel.stringValue = hint
        let current = Prefs.serverDisplaySize
        resolutionPopup.removeAllItems()
        var labels: [(String, String)] = []
        for (label, w, h) in Prefs.displayPresets {
            labels.append((label.replacingOccurrences(of: "x", with: "×"), "\(w)x\(h)"))
        }
        if !labels.contains(where: { $0.1 == current }) {
            labels.append((current.replacingOccurrences(of: "x", with: "×"), current))
        }
        resolutionPopup.addItems(withTitles: labels.map { $0.0 })
        if let index = labels.firstIndex(where: { $0.1 == current }) {
            resolutionPopup.selectItem(at: index)
        }
        qualityPopup.selectItem(at: Prefs.serverQuality == "standard" ? 0 : 1)
        portField.stringValue = String(Prefs.serverPort)
        updateStatus(server?.statusText ?? "", connected: server?.clientConnected == true,
                     needsPermission: server?.needsScreenRecording == true)
    }

    // MARK: - Actions

    @objc private func settingsChanged() {
        let index = resolutionPopup.indexOfSelectedItem
        let presets = Prefs.displayPresets
        if index < presets.count {
            let preset = presets[index]
            Prefs.serverDisplaySize = "\(preset.1)x\(preset.2)"
        }
        Prefs.serverQuality = qualityPopup.indexOfSelectedItem == 0 ? "standard" : "pixel"
        let port = Int(portField.stringValue) ?? Prefs.serverPort
        Prefs.serverPort = max(1, min(65535, port))
        // Resolution/quality/port only take effect on a fresh helper process.
        server?.restartForSettings()
    }

    @objc private func addCustomResolution() {
        let alert = NSAlert()
        alert.messageText = L.t("server.panel.custom")
        alert.addButton(withTitle: L.t("common.ok"))
        alert.addButton(withTitle: L.t("common.cancel"))
        let widthField = NSTextField(string: "3008")
        let heightField = NSTextField(string: "1692")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        for (index, pair) in [(L.t("client.hosts.width"), widthField), (L.t("client.hosts.height"), heightField)].enumerated() {
            let label = NSTextField(labelWithString: pair.0)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: 46 - index * 32, width: 70, height: 22)
            form.addSubview(label)
            pair.1.frame = NSRect(x: 80, y: 45 - index * 32, width: 200, height: 24)
            form.addSubview(pair.1)
        }
        alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn,
              let width = Int(widthField.stringValue), let height = Int(heightField.stringValue),
              (640...7680).contains(width), (480...4320).contains(height),
              width % 2 == 0, height % 2 == 0 else { return }
        Prefs.serverDisplaySize = "\(width)x\(height)"
        reload()
        server?.restartForSettings()
    }

    @objc private func toggleService() {
        if server?.wantedState == true {
            server?.stop()
        } else {
            server?.start()
        }
        reload()
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closePanel() {
        window?.close()
    }
}
