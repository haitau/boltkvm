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
    private let accessibilityButton = NSButton(title: L.t("server.panel.openAccessibility"),
                                               target: nil, action: nil)
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let portField = NSTextField(string: "")
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let rotateButton = NSButton(title: L.t("server.panel.rotate"),
                                        target: nil, action: nil)
    private let copyButton = NSButton(title: L.t("server.panel.copy"), target: nil, action: nil)
    /// Advanced alternative to the 8-character password: a 256-bit key for people
    /// who would rather paste 64 hex characters than a 40-bit password.
    private let staticButton = NSButton(title: L.t("server.panel.static"), target: nil, action: nil)
    /// What `copyButton` puts on the pasteboard (nil when the key is not a
    /// generated password, e.g. an old 64-hex file).
    private var currentPassword: String?
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
        permissionButton.frame = NSRect(x: 24, y: 284, width: 210, height: 24)
        permissionButton.isHidden = false
        content.addSubview(permissionButton)

        // Screen Recording and Accessibility are independent TCC services.
        // Both controls stay visible; a missing one must not hide the other.
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings)
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.frame = NSRect(x: 242, y: 284, width: 210, height: 24)
        accessibilityButton.isHidden = false
        content.addSubview(accessibilityButton)

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

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyPassword)
        copyButton.frame = NSRect(x: 24, y: 56, width: 130, height: 24)
        content.addSubview(copyButton)

        staticButton.bezelStyle = .rounded
        staticButton.target = self
        staticButton.action = #selector(useStaticKey)
        staticButton.frame = NSRect(x: 180, y: 56, width: 150, height: 24)
        content.addSubview(staticButton)

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

    /// Typing 8 characters on another keyboard is the annoying part, so make the
    /// panel's password one click away (selecting the hint text also works).
    @objc private func copyPassword() {
        guard let password = currentPassword else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(password, forType: .string)
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

    /// Swaps the 8-character password for a 256-bit key. Same effect as rotation
    /// (every client needs the new value), so it gets the same confirmation.
    @objc private func useStaticKey() {
        let alert = NSAlert()
        alert.messageText = L.t("server.panel.static.confirm.title")
        alert.informativeText = L.t("server.panel.static.confirm.body")
        alert.addButton(withTitle: L.t("server.panel.static"))
        alert.addButton(withTitle: L.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let key = try PSK.writeStaticKey()
            log("app: switched to a 256-bit static key")
            server?.restartForSettings()
            reload()
            let done = NSAlert()
            done.messageText = L.f("server.panel.static.done", key)
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
        // Keep both permission buttons available even after one is granted;
        // hiding the granted one is what previously left users with a single
        // button and no obvious way back to the other settings page.
        permissionButton.isHidden = false
        accessibilityButton.isHidden = false
        let needsAccessibility = server?.needsAccessibility == true
        let color: NSColor = (needsPermission || needsAccessibility)
            ? .systemOrange
            : (connected ? .systemGreen : .secondaryLabelColor)
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
        currentPassword = nil
        if let key = resolveAuthKey([]) {
            if let stored = PSK.storedText(), PSK.isGeneratedPassword(stored) {
                let normalized = PSK.normalize(stored)
                currentPassword = normalized
                hint += "\n" + L.f("server.panel.password", normalized)
            } else if let stored = PSK.storedText(), PSK.isStaticKey(stored) {
                currentPassword = stored
                hint += "\n" + L.f("server.panel.staticKey", PSK.shortKey(stored))
            }
            hint += "  " + L.f("server.panel.fingerprint", PSK.fingerprint(key))
        } else {
            hint += "\n" + L.t("server.panel.nokey")
        }
        hintLabel.stringValue = hint
        copyButton.isHidden = currentPassword == nil
        let current = Prefs.serverDisplaySize
        resolutionPopup.removeAllItems()
        var options = Prefs.displayOptions
        if let size = DisplaySize.parse(current),
           !options.contains(where: { $0.0 == size.width && $0.1 == size.height }) {
            options.append((size.width, size.height))
        }
        let keys = options.map { "\($0.0)x\($0.1)" }
        resolutionPopup.addItems(withTitles: options.map { Prefs.displayTitle("\($0.0)x\($0.1)") })
        for (index, key) in keys.enumerated() {
            resolutionPopup.item(at: index)?.representedObject = key
        }
        if let index = keys.firstIndex(of: current) {
            resolutionPopup.selectItem(at: index)
        }
        qualityPopup.selectItem(at: Prefs.serverQuality == "standard" ? 0 : 1)
        portField.stringValue = String(Prefs.serverPort)
        updateStatus(server?.statusText ?? "", connected: server?.clientConnected == true,
                     needsPermission: server?.needsScreenRecording == true)
    }

    // MARK: - Actions

    @objc private func settingsChanged() {
        if let key = resolutionPopup.selectedItem?.representedObject as? String {
            Prefs.serverDisplaySize = key
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
        let current = DisplaySize.parse(Prefs.serverDisplaySize)
        let widthField = NSTextField(string: String(current?.width ?? 3008))
        let heightField = NSTextField(string: String(current?.height ?? 1692))
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
              let size = DisplaySize.parse("\(widthField.stringValue)x\(heightField.stringValue)")
        else { return }
        Prefs.rememberDisplaySize((size.width, size.height))
        Prefs.serverDisplaySize = "\(size.width)x\(size.height)"
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
        _ = CGRequestScreenCaptureAccess()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closePanel() {
        window?.close()
    }
}
