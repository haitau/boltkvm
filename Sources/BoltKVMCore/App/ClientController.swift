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
    private var fullScreenButton: NSButton!
    private var statusLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var videoView: NSView!

    init() {
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

        // The remote gets the keyboard while the pointer is over the picture, so
        // the ⌃⌘F menu shortcut only works from the bar; this button is the
        // discoverable way in.
        fullScreenButton = NSButton(title: L.t("client.button.fullscreen"), target: self, action: #selector(toggleFullScreenAction(_:)))
        fullScreenButton.bezelStyle = .rounded

        statusLabel = NSTextField(labelWithString: L.t("client.state.idle"))
        statusLabel.textColor = .secondaryLabelColor
        statsLabel = NSTextField(labelWithString: "")
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right
        statsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [hostLabel, hostField, portLabel, portField,
                                      keyLabel, keyField, inputCheck, audioCheck,
                                      connectButton, fullScreenButton, statusLabel, statsLabel])
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
        content.addSubview(bar)
        content.addSubview(videoView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: bar.bottomAnchor),
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
            self.connectButton.title = self.session?.isActive == true ? L.t("client.button.disconnect") : L.t("client.button.connect")
            if case .failed = state {
                self.statusLabel.textColor = .systemRed
                self.connectButton.title = L.t("client.button.connect")
            }
        }
        session?.onStats = { [weak self] text in
            self?.statsLabel.stringValue = text
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Actions

    @objc private func connectPressed() {
        guard let session else { return }
        if session.isActive {
            session.disconnect()
            return
        }
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
        session.connect(host: host, port: port, key: explicitKey,
                        forwardInput: inputCheck.state == .on,
                        playAudio: audioCheck.state == .on)
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
        session?.disconnect()
    }
}
