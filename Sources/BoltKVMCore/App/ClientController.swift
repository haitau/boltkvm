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
    /// How much of 1:1 the picture gets, shown in the toolbar ("92%").
    private var scalePercent = 100
    /// Pixel size of the stream, kept so the percentage can be recomputed when
    /// the window resizes (full screen is how you get back to 100%).
    private var remotePixelSize = NSSize.zero
    /// Colour pipeline the stream is actually using, shown as "P3" when wide.
    private var streamColor = ColorMode.standard
    private var chromeTimer: Timer?
    private var appliedFullScreen: Bool?
    private var didLogInvisibleWindow = false
    /// Height of the native titlebar + toolbar band, measured while windowed.
    /// Full screen reuses it for the one tick between "toolbar shown" and the
    /// window reporting the new content layout rect.
    private var chromeHeight: CGFloat = 52
    /// The first fullscreen reveal of the native toolbar can lay out its items
    /// blank on this macOS; one hidden visible pass fixes it. Keep the extra
    /// pass out of later reveals so they stay instant.
    private var fullScreenToolbarPrimed = false
    /// When the pointer first reached the top edge; the toolbar only appears
    /// after a short dwell so brushing the edge mid-click does not move the
    /// picture.
    private var topEdgeEnteredAt: Date?

    private static let tbMission = NSToolbarItem.Identifier("boltkvm.missionControl")
    private static let tbDesktop = NSToolbarItem.Identifier("boltkvm.desktop")
    private static let tbStatus = NSToolbarItem.Identifier("boltkvm.status")
    /// Live `fps · bitrate` label hosted in the toolbar's trailing edge.
    private let toolbarStatusLabel = NSTextField(labelWithString: "")
    /// "桌面" becomes "还原窗口" after the remote moved its windows aside, so the
    /// second press does what the title says instead of toggling the remote back.
    private var desktopToolbarItem: NSToolbarItem?
    private var desktopHidden = false

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
            // Full-size content is what keeps AppKit from *resizing* the
            // fullscreen window when the toolbar reappears. Without it the
            // window loses the toolbar's height, the Metal drawable changes
            // aspect, and the remote picture is rescaled instead of moving down
            // as one piece (the Screen Sharing behaviour).
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L.t("client.window.title")
        window.isReleasedWhenClosed = false
        // Fullscreen puts the content under the titlebar. AppKit still draws a
        // 1 pt separator at the very top while the toolbar is hidden, and its
        // show/hide animation can leave that line flickering above the picture.
        // The window is all video, so there is nothing for a separator to
        // separate (A-4).
        window.titlebarSeparatorStyle = .none
        // Do NOT make the titlebar transparent with a black window background:
        // in light appearance the toolbar's label/icon color stays black, and a
        // transparent titlebar over black makes the whole toolbar (Mission
        // Control, Desktop, fullscreen) invisible. The separator is suppressed
        // by titlebarSeparatorStyle alone; keep the native titlebar material so
        // its controls remain legible.
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .black
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
        videoView = NSView(frame: .zero)
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.translatesAutoresizingMaskIntoConstraints = true

        let content = window.contentView!
        // The video is laid out by `layoutVideo()` rather than pinned to all
        // four edges: in fullscreen the toolbar is an overlay and the picture
        // has to move down without being resized.
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.addSubview(videoView)
        layoutVideo()

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
        session?.onEnd = { [weak self] in
            guard let self else { return }
            self.stopReportTimer(report: true)
            self.desktopHidden = false
            self.updateDesktopButton()
            self.refreshToolbarStatus()
        }
        session?.onFormat = { [weak self] width, height, color in
            guard let self else { return }
            self.streamColor = color
            self.refreshToolbarStatus()
            self.fitWindowToRemote(width: width, height: height)
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
        layoutVideo()
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
        // 用户只要求动作按钮居中：标题和右侧状态保持原样。
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        toolbar.centeredItemIdentifiers = [Self.tbMission, Self.tbDesktop]
    }

    /// A standard toolbar item, so AppKit draws the icon, label and pressed
    /// state itself. The old view-based stack was what stayed blank on the first
    /// fullscreen reveal.
    private func actionToolbarItem(_ identifier: NSToolbarItem.Identifier,
                                   title: String, symbol: String,
                                   tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.image = toolbarImage(symbol)
        item.toolTip = tip
        item.target = self
        item.action = action
        return item
    }

    private func toolbarImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: - Fullscreen chrome

    /// Where the remote picture lives inside the content view.
    ///
    /// Windowed: below the titlebar + toolbar band, which is what the old
    /// Auto Layout pinning did.
    /// Fullscreen, toolbar hidden: the whole screen.
    /// Fullscreen, toolbar shown: the same size, shifted down by the toolbar
    /// height. The top of the remote screen starts just below the toolbar and
    /// the bottom goes off-screen, exactly like Screen Sharing; the drawable is
    /// never resized, so the picture cannot change aspect ratio. `chrome` is
    /// the band height (52 pt windowed; 68/98 pt fullscreen depending on
    /// whether the menu bar is showing), passed in so the geometry is unit
    /// testable without a window.
    enum ChromeLayout {
        static func videoFrame(content: CGSize, chrome: CGFloat,
                               fullScreen: Bool, toolbarVisible: Bool) -> CGRect {
            let width = max(0, content.width)
            let height = max(0, content.height)
            if fullScreen, toolbarVisible {
                let shift = min(max(0, chrome), height)
                return CGRect(x: 0, y: -shift, width: width, height: height)
            }
            let visibleHeight = fullScreen ? height : max(0, height - chrome)
            return CGRect(x: 0, y: 0, width: width, height: visibleHeight)
        }
    }

    /// Recompute the video frame from the window's current chrome state. Cheap
    /// enough to call from the 5 Hz fullscreen poll.
    private func layoutVideo() {
        guard let window, let content = window.contentView else { return }
        // AppKit can recreate the separator when the toolbar visibility
        // changes; keep it off on every layout tick, not only on entry.
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        let bounds = content.bounds
        let measured = max(0, bounds.height - window.contentLayoutRect.height)
        if measured > 0 { chromeHeight = measured }
        let toolbarVisible = window.toolbar?.isVisible ?? false
        let fullScreen = window.styleMask.contains(.fullScreen)
        // In fullscreen the titlebar's extra strip otherwise sits over the
        // remote menu bar; hide it there and restore the windowed title so the
        // remote system bar stays visible below the toolbar.
        let titleVisibility: NSWindow.TitleVisibility = fullScreen ? .hidden : .visible
        if window.titleVisibility != titleVisibility {
            window.titleVisibility = titleVisibility
        }
        // The tick that reveals the toolbar runs before AppKit publishes the
        // new contentLayoutRect; use the last known band height for that frame
        // instead of showing one unshifted frame.
        var chrome = measured > 0 ? measured : (toolbarVisible ? chromeHeight : 0)
        if fullScreen, toolbarVisible {
            chrome = fullScreenChromeHeight
        }
        let frame = ChromeLayout.videoFrame(
            content: bounds.size,
            chrome: chrome,
            fullScreen: fullScreen,
            toolbarVisible: toolbarVisible
        )
        if videoView.frame != frame {
            videoView.frame = frame
        }
    }

    /// The AppKit child window that hosts the fullscreen toolbar. Its frame is
    /// the only authoritative source for where the toolbar actually ends.
    private var fullScreenToolbarWindow: NSWindow? {
        window?.childWindows?.first {
            String(describing: type(of: $0)).contains("ToolbarFullScreen")
        }
    }

    private var fullScreenChromeHeight: CGFloat {
        guard let window else { return 52 }
        let measured = window.contentView.map {
            $0.bounds.height - window.contentLayoutRect.height
        } ?? 0
        let base = (measured >= 40 && measured <= 140) ? measured : 52
        // The visible toolbar is 52 pt. When the app menu bar pops out in
        // fullscreen, AppKit moves the toolbar child down by the menu bar height
        // (about 30 pt); the remote picture must move by both, otherwise the
        // toolbar covers the remote Mac's system menu bar. The child's top off-
        // set is the menu bar height; never use its 68 pt height (bottom 16 pt
        // is transparent, which would leave a black strip).
        let screenTop = window.screen?.frame.maxY ?? window.frame.maxY
        let childTop = fullScreenToolbarWindow?.frame.maxY ?? screenTop
        let menuOffset = max(0, min(60, screenTop - childTop))
        return base + menuOffset
    }

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

    /// Reveal the native toolbar. On the first reveal of a fullscreen session,
    /// give AppKit one extra visible pass: the first pass creates the
    /// `NSToolbarFullScreenWindow`, the second lays out its standard items.
    /// Without this the first top-edge dwell can show an empty band.
    private func revealFullScreenToolbar() {
        guard let window, let toolbar = window.toolbar else { return }
        if fullScreenToolbarPrimed {
            toolbar.isVisible = true
            layoutVideo()
            log("fs: toolbar shown at the top edge (content shifted down by \(Int(fullScreenChromeHeight)) pt)")
            return
        }
        fullScreenToolbarPrimed = true
        toolbar.isVisible = true
        layoutVideo()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.styleMask.contains(.fullScreen) else { return }
            window.toolbar?.isVisible = false
            self.layoutVideo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, let window = self.window,
                      window.styleMask.contains(.fullScreen) else { return }
                window.toolbar?.validateVisibleItems()
                window.toolbar?.isVisible = true
                self.layoutVideo()
                log("fs: toolbar shown at the top edge (content shifted down by \(Int(self.fullScreenChromeHeight)) pt)")
            }
        }
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
            fullScreenToolbarPrimed = false
            window.titlebarSeparatorStyle = .none
            topEdgeEnteredAt = nil
            layoutVideo()
            log("fs: chrome applied (fullscreen=\(fullScreen), fullSizeContent=true)")
            if fullScreen {
                // Give AppKit a hidden visible pass before the user reaches the
                // top edge. The fullscreen toolbar window is created lazily and
                // its first pass can be empty; warming it here keeps the first
                // real reveal instant. Skip if the pointer is already at the
                // top, since the reveal path has its own fallback.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self, let window = self.window,
                          window.styleMask.contains(.fullScreen),
                          window.toolbar?.isVisible != true,
                          NSEvent.mouseLocation.y < (window.screen?.frame.maxY ?? 0) - 110
                    else { return }
                    // Lay out the fullscreen toolbar invisibly: the first real
                    // user reveal then reuses a populated NSToolbarFullScreenWindow.
                    self.fullScreenToolbarWindow?.alphaValue = 0
                    window.toolbar?.isVisible = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self, let window = self.window,
                              window.styleMask.contains(.fullScreen) else { return }
                        window.toolbar?.isVisible = false
                        self.fullScreenToolbarWindow?.alphaValue = 1
                        self.layoutVideo()
                        self.fullScreenToolbarPrimed = true
                    }
                }
            }
        }
        guard fullScreen, let screen = window.screen else {
            layoutVideo()
            return
        }
        let y = NSEvent.mouseLocation.y
        let top = screen.frame.maxY
        let visible = window.toolbar?.isVisible ?? false
        // A short dwell at the edge avoids popping the chrome (and moving the
        // picture) when the pointer merely crosses the top on its way to a
        // remote menu item.
        if y > top - 4 {
            if visible {
                topEdgeEnteredAt = nil
            } else {
                if topEdgeEnteredAt == nil { topEdgeEnteredAt = Date() }
                if let entered = topEdgeEnteredAt, Date().timeIntervalSince(entered) >= 0.2 {
                    topEdgeEnteredAt = nil
                    revealFullScreenToolbar()
                }
            }
        } else {
            topEdgeEnteredAt = nil
            // Revealing the toolbar moves the pointer's relative position by the
            // toolbar height; the hide threshold has to clear that band or the
            // two states fight (the old 110 pt hysteresis).
            if y < top - 110, visible {
                window.toolbar?.isVisible = false
                layoutVideo()
                log("fs: toolbar hidden")
            }
        }
        // Covers the window/content relayout that follows a toolbar change.
        layoutVideo()
    }

    deinit {
        chromeTimer?.invalidate()
        reportTimer?.invalidate()
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
        let color = (host.color ?? 0) == ColorMode.wide.rawValue ? ColorMode.wide : .standard
        if let width = host.width, let height = host.height, width > 0, height > 0 {
            session.requestedConfig = SessionConfig(width: width, height: height, quality: 1, color: color)
        } else {
            session.requestedConfig = nil
        }
        session.connect(host: host.host, port: host.port, key: explicitKey,
                        forwardInput: forwardInput, playAudio: playAudio,
                        shareClipboard: Prefs.clipboard)
    }

    /// Match the window to the remote picture, at 1:1 when that fits.
    ///
    /// The window is now full-size content (`styleMask` contains
    /// `.fullSizeContentView`), so its content height includes the titlebar +
    /// toolbar band. The *picture* height is therefore content height minus
    /// that band; the old calculation added the chrome through
    /// `frameRect(forContentRect:)`, which no longer grows the frame. Keeping
    /// the picture area at one stream pixel per physical pixel is what makes
    /// text sharp, and full screen on a matching display is still 100%.
    private func fitWindowToRemote(width: Int, height: Int) {
        guard width > 0, height > 0, let window else { return }
        remotePixelSize = NSSize(width: width, height: height)

        // A resolution change while fullscreen must not resize the window: the
        // renderer letterboxes the new aspect, and layoutVideo keeps the
        // toolbar shift intact.
        if window.styleMask.contains(.fullScreen) {
            layoutVideo()
            updateScalePercent()
            log("window: remote \(width)x\(height) px while fullscreen; drawable left unchanged")
            return
        }

        let screen = window.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = measuredChromeHeight(in: window)
        let ideal = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let maxWidth = visible.width
        let maxHeight = max(400, visible.height - chrome)
        var picture = ideal
        if ideal.width > maxWidth || ideal.height > maxHeight {
            let factor = min(maxWidth / ideal.width, maxHeight / ideal.height)
            picture = NSSize(width: (ideal.width * factor).rounded(.down),
                             height: (ideal.height * factor).rounded(.down))
        }
        // Keep the window's content aspect equal to picture + chrome; at the
        // fitted size that gives the picture the remote aspect exactly.
        window.contentAspectRatio = NSSize(width: picture.width, height: picture.height + chrome)
        let content = NSSize(width: picture.width, height: picture.height + chrome)
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        let origin = NSPoint(x: (visible.width - frameSize.width) / 2,
                             y: (visible.height - frameSize.height) / 2)
        let frame = NSRect(x: visible.minX + origin.x.rounded(.down),
                           y: visible.minY + origin.y.rounded(.down),
                           width: frameSize.width, height: frameSize.height)
        window.setFrame(frame, display: true)
        layoutVideo()
        let percent = Int(((picture.width * scale / CGFloat(width)) * 100).rounded())
        scalePercent = percent
        refreshToolbarStatus()
        log(String(format: "window: remote %dx%d px -> picture %.0fx%.0f pt (%d%% of 1:1, chrome %.0f, window %.0fx%.0f, screen %.0fx%.0f, origin %.0f,%.0f)",
                   width, height, picture.width, picture.height, percent, chrome,
                   frame.width, frame.height, visible.width, visible.height, frame.minX, frame.minY))
    }

    /// Native titlebar + toolbar band height in the current window. Measured
    /// rather than hard-coded: `.unified` vs `.unifiedCompact` and future macOS
    /// releases differ, and fullscreen must shift by exactly that band.
    private func measuredChromeHeight(in window: NSWindow) -> CGFloat {
        let contentHeight = window.contentView?.bounds.height ?? window.frame.height
        let measured = max(0, contentHeight - window.contentLayoutRect.height)
        if measured > 0 { chromeHeight = measured }
        return measured > 0 ? measured : chromeHeight
    }

    /// `已连接 · 24 fps · 385 Mbps · 92%` lives in the toolbar's trailing edge.
    /// The trailing percentage is the picture scale: 100% is 1:1 (sharp), lower
    /// means the window is smaller than the stream and the image is resampled.
    private func refreshToolbarStatus() {
        var parts: [String] = []
        if !stateText.isEmpty { parts.append(stateText) }
        if !statsText.isEmpty { parts.append(statsText) }
        if session?.isActive == true, scalePercent < 100 {
            parts.append("\(scalePercent)%")
        }
        if session?.isActive == true, streamColor == .wide {
            parts.append("P3")
        }
        toolbarStatusLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: - Remote system shortcuts

    /// Mission Control (Spaces overview).
    @objc func showMissionControl() {
        // Mission Control is a mode, not an action: you have to be able to leave
        // it, and with forwarding off there is no Esc. Say so instead of
        // silently switching forwarding on for the rest of the session (that
        // also overrode a host configured with "no input").
        if session?.isForwardingInput != true {
            stateText = L.t("client.remote.needInput")
            refreshToolbarStatus()
            return
        }
        session?.sendCommand(.missionControl)
    }

    /// Show Desktop.
    @objc func showDesktop() {
        desktopHidden.toggle()
        updateDesktopButton()
        session?.sendCommand(desktopHidden ? .showDesktop : .hideDesktop)
    }

    private func updateDesktopButton() {
        guard let item = desktopToolbarItem else { return }
        item.label = desktopHidden ? L.t("client.toolbar.desktop.restore")
                                   : L.t("client.toolbar.desktop")
        item.paletteLabel = item.label
        item.toolTip = desktopHidden ? L.t("client.toolbar.desktop.restore.tip")
                                     : L.t("client.toolbar.desktop.tip")
        item.image = toolbarImage(desktopHidden ? "macwindow.on.rectangle" : "display")
    }

    @objc func toggleFullScreenAction(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    func shutdown() {
        session?.disconnect()
        session = nil
        window?.close()
    }

    func windowDidResize(_ notification: Notification) {
        layoutVideo()
        updateScalePercent()
    }

    /// Recompute how much of 1:1 the window currently shows. The drawable is
    /// view bounds x backing scale, which is what the picture is resampled to.
    private func updateScalePercent() {
        guard remotePixelSize.width > 0, let window else { return }
        let scale = (window.screen ?? NSScreen.main)?.backingScaleFactor ?? 2
        let points = renderer?.view.bounds.width ?? window.contentLayoutRect.width
        let percent = Int(((points * scale / remotePixelSize.width) * 100).rounded())
        guard percent != scalePercent else { return }
        scalePercent = percent
        refreshToolbarStatus()
    }

    func windowWillClose(_ notification: Notification) {
        log("window: closed by user")
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
        [.flexibleSpace, Self.tbMission, Self.tbDesktop, .flexibleSpace, Self.tbStatus]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.tbMission:
            return actionToolbarItem(Self.tbMission,
                                     title: L.t("client.toolbar.missionControl"),
                                     symbol: "square.grid.2x2",
                                     tip: L.t("client.toolbar.missionControl.tip"),
                                     action: #selector(showMissionControl))
        case Self.tbDesktop:
            let desktop = actionToolbarItem(Self.tbDesktop,
                                            title: L.t("client.toolbar.desktop"),
                                            symbol: "display",
                                            tip: L.t("client.toolbar.desktop.tip"),
                                            action: #selector(showDesktop))
            desktopToolbarItem = desktop
            return desktop
        case Self.tbStatus:
            toolbarStatusLabel.setFrameSize(NSSize(width: 150, height: 18))
            toolbarStatusLabel.alignment = .right
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = ""
            item.paletteLabel = L.t("client.label.stats")
            item.view = toolbarStatusLabel
            return item
        default:
            return nil
        }
    }
}
