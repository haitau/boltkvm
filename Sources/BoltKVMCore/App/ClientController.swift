import AppKit
import Metal
import Foundation

/// Client role window: the remote screen, and nothing else. Which machine, key,
/// input and audio all come from the connection list (that is where a "连接" is
/// configured); status lives in the toolbar's trailing edge.
final class ClientController: NSWindowController, NSWindowDelegate {
    private var renderer: Renderer?
    /// 60 s windowed report from the renderer, so a long GUI session leaves the
    /// same per-window fps/latency series the CLI client logs.
    private var reportTimer: Timer?
    private var session: ClientSession?

    private var videoView: NSView!
    /// Connection state, mirrored into the toolbar's trailing label.
    private var stateText = L.t("client.state.idle")
    private var statsText = ""
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
            DispatchQueue.main.async { [weak self] in self?.connect(preset) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        videoView = NSView()
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: content.topAnchor),
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
            stateText = L.f("client.renderer.failed", error.localizedDescription)
            refreshToolbarStatus()
        }

        session = renderer.map { ClientSession(renderer: $0) }
        session?.onState = { [weak self] state in
            guard let self else { return }
            self.stateText = state.text
            self.toolbarStatusLabel.textColor = state == .streaming ? .systemGreen : .secondaryLabelColor
            self.refreshToolbarStatus()
            // Closing the window is the disconnect (R4); there is no button.
            if state == .streaming, self.reportTimer == nil {
                self.reportTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.renderer?.reportWindow()
                }
            } else if !(self.session?.isActive == true) {
                self.stopReportTimer(report: true)
            }
        }
        session?.onFormat = { [weak self] width, height in
            self?.fitWindowToRemote(width: width, height: height)
        }
        session?.onStats = { [weak self] text in
            guard let self else { return }
            self.statsText = text
            self.refreshToolbarStatus()
        }
        toolbarStatusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        toolbarStatusLabel.textColor = .secondaryLabelColor
        toolbarStatusLabel.alignment = .right
        installToolbar()
        setupFullScreenChrome()
    }

    private func stopReportTimer(report: Bool) {
        guard reportTimer != nil else { return }
        reportTimer?.invalidate()
        reportTimer = nil
        if report { renderer?.report() }
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

    /// Connect using the saved host. The window has no fields of its own: the
    /// list is where a connection is configured.
    private func connect(_ host: SavedHost) {
        guard let session, !session.isActive else { return }
        guard !host.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            stateText = L.t("client.host.required")
            refreshToolbarStatus()
            return
        }
        Prefs.host = host.host
        Prefs.port = Int(host.port)
        let forwardInput = host.forwardInput ?? Prefs.forwardInput
        let playAudio = host.audio ?? Prefs.audio
        Prefs.forwardInput = forwardInput
        Prefs.audio = playAudio
        let explicitKey: Data? = host.pskAccount
            .flatMap { HostSecrets.get(account: $0) }
            .flatMap { resolveAuthKey(["--key", $0]) }
        session.inputView = renderer?.view
        if let width = host.width, let height = host.height, width > 0, height > 0 {
            session.requestedConfig = SessionConfig(width: width, height: height, quality: 1)
        } else {
            session.requestedConfig = nil
        }
        session.connect(host: host.host, port: host.port, key: explicitKey,
                        forwardInput: forwardInput, playAudio: playAudio)
    }

    /// Match the window to the remote picture. Screen Sharing does the same:
    /// a 16:9 remote in a 16:10 window leaves two black bands that read as "the
    /// picture is broken", so the window adopts the stream's aspect on connect.
    private func fitWindowToRemote(width: Int, height: Int) {
        guard width > 0, height > 0, let window else { return }
        let aspect = NSSize(width: width, height: height)
        window.contentAspectRatio = aspect
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var contentWidth = window.contentLayoutRect.width
        if contentWidth <= 0 { contentWidth = 1200 }
        var contentHeight = contentWidth * CGFloat(height) / CGFloat(width)
        // Keep the whole window on screen, with the toolbar and title bar.
        let maxHeight = visible.height - 80
        if contentHeight > maxHeight {
            contentHeight = maxHeight
            contentWidth = contentHeight * CGFloat(width) / CGFloat(height)
        }
        window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        log(String(format: "window: fitted to remote %dx%d -> content %.0fx%.0f",
                   width, height, contentWidth, contentHeight))
    }

    /// `已连接 · 24 fps · 385 Mbps` lives in the toolbar's trailing edge.
    private func refreshToolbarStatus() {
        var text = stateText
        if !statsText.isEmpty {
            text = text.isEmpty ? statsText : "\(text) · \(statsText)"
        }
        toolbarStatusLabel.stringValue = text
    }

    // MARK: - Remote system shortcuts

    /// Mission Control (Spaces overview).
    @objc func showMissionControl() {
        // Mission Control is a mode, not an action: you have to be able to leave
        // it. With input forwarding off there is no Esc, so the remote just sits
        // in the overview and reads as "frozen desktop" — which is exactly how
        // this looked in testing.
        // With input forwarding off there is no Esc to leave the overview, so
        // turn it on for the action.
        session?.setInputEnabled(true)
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
