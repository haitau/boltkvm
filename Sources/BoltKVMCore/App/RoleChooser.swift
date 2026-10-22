import AppKit

/// First run (and "重新选择角色") lands here. Two buttons, one decision: this
/// machine is either the one being driven or the one driving.
final class RoleChooserController: NSWindowController {
    private let onPick: (Role) -> Void

    init(onPick: @escaping (Role) -> Void) {
        self.onPick = onPick
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "BoltKVM"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(in: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build(in window: NSWindow) {
        let title = NSTextField(labelWithString: "这台机器要做什么？")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "一个 app，两种角色。服务端创建一块虚拟屏并共享它，客户端连接过去显示画面、转发键鼠。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 3

        let server = makeButton(
            title: "作为被控端",
            detail: "这台机器被连接（无头 Mac mini 那种用法）",
            action: #selector(pickServer)
        )
        let client = makeButton(
            title: "作为主控端",
            detail: "连接另一台机器，把它的画面显示在这里",
            action: #selector(pickClient)
        )

        let hint = NSTextField(labelWithString: "角色随时可以在菜单里切换，选择会记住。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, subtitle, server, client, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(24, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        for view in [server, client] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        }
    }

    private func makeButton(title: String, detail: String, action: Selector) -> NSButton {
        let button = NSButton(title: "\(title)\n\(detail)", target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return button
    }

    @objc private func pickServer() { onPick(.server) }
    @objc private func pickClient() { onPick(.client) }
}
