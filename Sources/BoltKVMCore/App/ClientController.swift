import AppKit
import Metal
import Foundation

/// Client role window: a connection bar on top, the remote screen below.
final class ClientController: NSWindowController, NSWindowDelegate {
    private var renderer: Renderer?
    private var session: ClientSession?

    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var keyField: NSSecureTextField!
    private var inputCheck: NSButton!
    private var audioCheck: NSButton!
    private var connectButton: NSButton!
    private var statusLabel: NSTextField!
    private var videoView: NSView!
    private var bar: NSStackView!
    /// The connect bar is windowed-only chrome; in fullscreen the toolbar takes
    /// over (it auto-reveals at the top edge, like Screen Sharing).
    private var videoTopToBar: NSLayoutConstraint?
    private var videoTopToContent: NSLayoutConstraint?
    private var chromeTimer: Timer?
    private var appliedFullScreen: Bool?
    private var didLogInvisibleWindow = false

    private static let tbRemote = NSToolbarItem.Identifier("boltkvm.remote")
    private static let tbStatus = NSToolbarItem.Identifier("boltkvm.status")
    /// Live `fps · bitrate` label hosted in the toolbar's trailing edge.
    private let toolbarStatusLabel = NSTextField(labelWithString: "")

    /// Set when the list window opens this controller: prefills the fields and
    /// connects right away.
    private let preset: SavedHost?
    /// Called after the window closes, so the app can go back to the list instead
    /// of quitting.
    var onClosed: (() -> Void)?

    init(preset: SavedHost? = nil) {
        self.preset = preset
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.t("client.window.title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        if let preset {
            hostField.stringValue = preset.host
            portField.stringValue = String(preset.port)
            DispatchQueue.main.async { [weak self] in self?.connectPressed() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        let hostLabel = label(L.t("client.label.host"))
        hostField = NSTextField(string: Prefs.host)
        hostField.placeholderString = L.t("client.placeholder.host")
        hostField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let portLabel = label(L.t("client.label.port"))
        portField = NSTextField(string: String(Prefs.port))
        portField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let keyLabel = label(L.t("client.label.key"))
        keyField = NSSecureTextField(string: "")
        keyField.placeholderString = L.t("client.placeholder.key")
        keyField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        inputCheck = NSButton(checkboxWithTitle: L.t("client.check.input"), target: nil, action: nil)
        inputCheck.state = Prefs.forwardInput ? .on : .off
        audioCheck = NSButton(checkboxWithTitle: L.t("client.check.audio"), target: nil, action: nil)
        audioCheck.state = Prefs.audio ? .on : .off

        connectButton = NSButton(title: L.t("client.button.connect"), target: self, action: #selector(connectPressed))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: L.t("client.state.idle"))
        statusLabel.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [hostLabel, hostField, portLabel, portField,
                                      keyLabel, keyField, inputCheck, audioCheck,
                                      connectButton, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false

        videoView = NSView()
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        self.bar = bar
        content.addSubview(bar)
        content.addSubview(videoView)
        let videoToBar = videoView.topAnchor.constraint(equalTo: bar.bottomAnchor)
        let videoToContent = videoView.topAnchor.constraint(equalTo: content.topAnchor)
        videoToBar.isActive = true
        videoTopToBar = videoToBar
        videoTopToContent = videoToContent
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            videoView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain: "boltkvm", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L.t("client.no.metal")])
            }
            let renderer = try Renderer(device: device)
            self.renderer = renderer
            renderer.view.translatesAutoresizingMaskIntoConstraints = true
            renderer.view.frame = videoView.bounds
            renderer.view.autoresizingMask = [.width, .height]
            videoView.addSubview(renderer.view)
        } catch {
            statusLabel.stringValue = L.f("client.renderer.failed", error.localizedDescription)
            statusLabel.textColor = .systemRed
        }

        session = renderer.map { ClientSession(renderer: $0) }
        session?.onState = { [weak self] state in
            guard let self else { return }
            self.statusLabel.stringValue = state.text
            self.statusLabel.textColor = state == .streaming ? .systemGreen : .secondaryLabelColor
            // No 断开 button: closing the window is the disconnect (R4).
            self.connectButton.isHidden = self.session?.isActive == true
        }
        session?.onStats = { [weak self] text in
            self?.toolbarStatusLabel.stringValue = text
        }
        toolbarStatusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        toolbarStatusLabel.textColor = .secondaryLabelColor
        toolbarStatusLabel.alignment = .right
        installToolbar()
        setupFullScreenChrome()
    }

    // MARK: - Toolbar

    /// Screen Sharing's layout: 控制 | App 调度中心 桌面 | 全屏.
    /// The toolbar also survives fullscreen, where AppKit reveals it when the
    /// pointer reaches the top edge — the reason the remote actions live here
    /// rather than in the connect bar (which fullscreen hides).
    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "boltkvm.client")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // 屏幕共享的三个按钮是居中的；middle item 置中后两侧自然分开。
        // One view-based item, centred as a whole: with individual items only the
        // named one is centred and the rest pile up at the leading edge.
        toolbar.centeredItemIdentifier = Self.tbRemote
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// The three remote actions as one horizontally centred group. Screen
    /// Sharing puts them in the middle of the title bar; individual NSToolbarItems
    /// cannot be centred as a group, so they live in one view-based item.
    private func remoteActionsView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 26
        stack.alignment = .centerY
        // App Exposé is missing on purpose: macOS 26 offers no permission-free
        // way to trigger it. The Dock notification that still drives Mission
        // Control and Show Desktop (com.apple.expose.front.awake) is accepted and
        // then does nothing here; the keyboard route needs Accessibility, the
        // AppleScript route needs Automation, and this app gets neither.
        let entries: [(String, String, Selector)] = [
            (L.t("client.toolbar.missionControl"), "square.grid.2x2", #selector(showMissionControl)),
            (L.t("client.toolbar.desktop"), "display", #selector(showDesktop)),
        ]
        for (title, symbol, action) in entries {
            let button = NSButton(title: title, target: self, action: action)
            button.image = toolbarImage(symbol)
            button.imagePosition = .imageAbove
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(button)
        }
        stack.setFrameSize(stack.fittingSize)
        return stack
    }

    private func toolbarImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: - Fullscreen chrome

    /// Neither the `windowWillEnterFullScreen` delegate callbacks nor the
    /// did-* notifications fired for this window (verified with temporary logs),
    /// so the fullscreen chrome is polled instead: the style mask is the truth,
    /// and the pointer position decides whether the toolbar is out. This is the
    /// Screen Sharing behaviour — hidden by default, revealed at the top edge.
    private func setupFullScreenChrome() {
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tickChrome()
        }
        RunLoop.main.add(timer, forMode: .common)
        chromeTimer = timer
    }

    private func tickChrome() {
        guard let window else { return }
        // B2 instrumentation: the window has vanished before while the session was
        // still streaming. Record whether it was *closed* (windowWillClose logs a
        // stack) or merely stopped being visible.
        if !window.isVisible && !didLogInvisibleWindow {
            didLogInvisibleWindow = true
            log("window: not visible (closed=\(window.isReleasedWhenClosed), session=\(session?.isActive == true), key=\(window.isKeyWindow))")
        } else if window.isVisible {
            didLogInvisibleWindow = false
        }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if appliedFullScreen != fullScreen {
            appliedFullScreen = fullScreen
            bar.isHidden = fullScreen
            videoTopToContent?.isActive = fullScreen
            videoTopToBar?.isActive = !fullScreen
            window.toolbar?.isVisible = !fullScreen
            log("fs: chrome applied (fullscreen=\(fullScreen))")
        }
        guard fullScreen, let screen = window.screen else { return }
        let y = NSEvent.mouseLocation.y
        let top = screen.frame.maxY
        let visible = window.toolbar?.isVisible ?? false
        // Revealing the toolbar pushes the pointer down by the toolbar height,
        // so the hide threshold has to clear that band or the two states fight.
        if y > top - 4, !visible {
            window.toolbar?.isVisible = true
            log("fs: toolbar shown at the top edge")
        } else if y < top - 110, visible {
            window.toolbar?.isVisible = false
            log("fs: toolbar hidden")
        }
    }

    deinit {
        chromeTimer?.invalidate()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Actions

    @objc private func connectPressed() {
        guard let session, !session.isActive else { return }
        // Disconnecting is done by closing the window (R4), so this only connects.
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            statusLabel.stringValue = L.t("client.host.required")
            statusLabel.textColor = .systemRed
            return
        }
        Prefs.host = host
        let port = UInt16(portField.stringValue) ?? 7474
        Prefs.port = Int(port)
        Prefs.forwardInput = inputCheck.state == .on
        Prefs.audio = audioCheck.state == .on
        let explicitKey: Data? = keyField.stringValue.isEmpty
            ? nil
            : resolveAuthKey(["--key", keyField.stringValue])
        session.inputView = renderer?.view
        // Ask for the size saved for this host; nil means "whatever the server
        // already uses", which is what an old entry gets.
        if let preset, let width = preset.width, let height = preset.height,
           width > 0, height > 0 {
            session.requestedConfig = SessionConfig(width: width, height: height, quality: 1)
        } else {
            session.requestedConfig = nil
        }
        session.connect(host: host, port: port, key: explicitKey,
                        forwardInput: inputCheck.state == .on,
                        playAudio: audioCheck.state == .on)
    }

    // MARK: - Remote system shortcuts

    /// Mission Control (Spaces overview).
    @objc func showMissionControl() {
        // Mission Control is a mode, not an action: you have to be able to leave
        // it. With input forwarding off there is no Esc, so the remote just sits
        // in the overview and reads as "frozen desktop" — which is exactly how
        // this looked in testing.
        if inputCheck.state == .off {
            inputCheck.state = .on
            Prefs.forwardInput = true
            session?.setInputEnabled(true)
        }
        session?.sendCommand(.missionControl)
    }

    /// Show Desktop.
    @objc func showDesktop() {
        session?.sendCommand(.showDesktop)
    }

    @objc func toggleFullScreenAction(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    func shutdown() {
        session?.disconnect()
        session = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        log("window: will close — stack: \(Thread.callStackSymbols.dropFirst().prefix(10).joined(separator: " <- "))")
        // Closing the window *is* the disconnect (R4); for the client role the
        // app has nothing left to do, so it quits the way a document window would.
        session?.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.onClosed?()
        }
    }
}

extension ClientController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tbRemote, .flexibleSpace, Self.tbStatus]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        switch identifier {
        case Self.tbRemote:
            item.label = ""
            item.paletteLabel = L.t("client.toolbar.app")
            item.view = remoteActionsView()
        case Self.tbStatus:
            toolbarStatusLabel.setFrameSize(NSSize(width: 150, height: 18))
            toolbarStatusLabel.alignment = .right
            item.label = ""
            item.paletteLabel = L.t("client.label.stats")
            item.view = toolbarStatusLabel
        default:
            return nil
        }
        return item
    }
}
