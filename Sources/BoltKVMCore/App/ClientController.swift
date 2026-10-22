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
    private var statsLabel: NSTextField!
    private var videoView: NSView!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BoltKVM — 主控端"
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
        let hostLabel = label("主机")
        hostField = NSTextField(string: Prefs.host)
        hostField.placeholderString = "10.0.20.2"
        hostField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let portLabel = label("端口")
        portField = NSTextField(string: String(Prefs.port))
        portField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let keyLabel = label("密钥")
        keyField = NSSecureTextField(string: "")
        keyField.placeholderString = "留空用 ~/.boltkvm-key"
        keyField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        inputCheck = NSButton(checkboxWithTitle: "转发键鼠", target: nil, action: nil)
        inputCheck.state = Prefs.forwardInput ? .on : .off
        audioCheck = NSButton(checkboxWithTitle: "音频", target: nil, action: nil)
        audioCheck.state = Prefs.audio ? .on : .off

        connectButton = NSButton(title: "连接", target: self, action: #selector(connectPressed))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: "未连接")
        statusLabel.textColor = .secondaryLabelColor
        statsLabel = NSTextField(labelWithString: "")
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right
        statsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [hostLabel, hostField, portLabel, portField,
                                      keyLabel, keyField, inputCheck, audioCheck,
                                      connectButton, statusLabel, statsLabel])
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
                              userInfo: [NSLocalizedDescriptionKey: "没有可用的 Metal 设备"])
            }
            let renderer = try Renderer(device: device)
            self.renderer = renderer
            renderer.view.translatesAutoresizingMaskIntoConstraints = true
            renderer.view.frame = videoView.bounds
            renderer.view.autoresizingMask = [.width, .height]
            videoView.addSubview(renderer.view)
        } catch {
            statusLabel.stringValue = "渲染器初始化失败：\(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }

        session = renderer.map { ClientSession(renderer: $0) }
        session?.onState = { [weak self] state in
            guard let self else { return }
            self.statusLabel.stringValue = state.text
            self.statusLabel.textColor = state == .streaming ? .systemGreen : .secondaryLabelColor
            self.connectButton.title = self.session?.isActive == true ? "断开" : "连接"
            if case .failed = state {
                self.statusLabel.textColor = .systemRed
                self.connectButton.title = "连接"
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
            statusLabel.stringValue = "先填主机地址"
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
