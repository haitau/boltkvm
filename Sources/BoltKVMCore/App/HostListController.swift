import AppKit

/// The connection list (R1): saved remote Macs, with add / edit / delete and
/// double-click to connect. Replaces the old "launch straight into an empty
/// video window" flow.
final class HostListController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called when the user picks a host to connect to.
    var onConnect: ((SavedHost) -> Void)?
    /// Called when the list window closes and nothing else is open.
    var onClosed: (() -> Void)?

    private let store = HostStore.shared
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L.t("client.hosts.empty"))
    private let versionLabel = NSTextField(labelWithString: "BoltKVM \(AppVersion.display)")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "\(L.t("client.hosts.title"))  ·  \(AppVersion.display)"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: .init("host"))
        column.title = L.t("client.hosts.column")
        column.width = 520
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectSelected)
        table.style = .inset

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(addHost))
        add.bezelStyle = .texturedRounded
        let edit = NSButton(title: L.t("client.hosts.edit"), target: self, action: #selector(editHost))
        edit.bezelStyle = .rounded
        let remove = NSButton(title: L.t("client.hosts.remove"), target: self, action: #selector(removeHost))
        remove.bezelStyle = .rounded
        let connect = NSButton(title: L.t("client.button.connect"), target: self, action: #selector(connectSelected))
        connect.bezelStyle = .rounded
        connect.keyEquivalent = "\r"

        versionLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let buttons = NSStackView(views: [add, edit, remove, NSView(), versionLabel, connect])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttons)
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    func reload() {
        store.reload()
        table.reloadData()
        emptyLabel.isHidden = !store.hosts.isEmpty
        // An empty list is useless without a way in, so preselect nothing and let
        // the ＋ button (or a double-click after adding) do the work.
        table.deselectAll(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.hosts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let host = store.hosts[row]
        let view = NSTableCellView()
        let name = NSTextField(labelWithString: host.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let size = host.width.flatMap { w in host.height.map { "\(w)×\($0)" } } ?? "—"
        let detail = NSTextField(labelWithString: "\(host.host):\(host.port) · \(size)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -6),
        ])
        return view
    }

    private var selectedHost: SavedHost? {
        let row = table.selectedRow
        guard row >= 0, row < store.hosts.count else { return nil }
        return store.hosts[row]
    }

    // MARK: - Actions

    @objc private func connectSelected() {
        guard let host = selectedHost ?? store.hosts.first else { return }
        onConnect?(host)
    }

    @objc private func addHost() {
        presentEditor(host: nil)
    }

    @objc private func editHost() {
        guard let host = selectedHost else { return }
        presentEditor(host: host)
    }

    @objc private func removeHost() {
        guard let host = selectedHost else { return }
        store.remove(id: host.id)
        reload()
    }


    // MARK: - Resolutions

    /// 3008×1692 is the virtual display the mini runs today; a new entry starts
    /// from it instead of a meaningless "default".
    static let defaultSize = (3008, 1692)

    /// The one catalog shared with the controlled Mac's menu: built-in presets
    /// plus the custom sizes remembered on this Mac.
    static func resolutionOptions() -> [(Int, Int)] {
        Prefs.displayOptions
    }

    static func rememberCustomResolution(_ size: (Int, Int)) {
        Prefs.rememberDisplaySize(size)
    }

    static func sizeTitle(_ size: (Int, Int)) -> String {
        Prefs.displayTitle("\(size.0)x\(size.1)")
    }

    /// Asks for an explicit W×H. Returns nil when cancelled or invalid.
    private func askForCustomResolution() -> (Int, Int)? {
        let alert = NSAlert()
        alert.messageText = L.t("client.hosts.addResolution")
        alert.addButton(withTitle: L.t("common.ok"))
        alert.addButton(withTitle: L.t("common.cancel"))
        let widthField = NSTextField(string: String(HostListController.defaultSize.0))
        let heightField = NSTextField(string: String(HostListController.defaultSize.1))
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
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let size = DisplaySize.parse("\(widthField.stringValue)x\(heightField.stringValue)") else {
            return nil
        }
        return (size.width, size.height)
    }

    private func presentEditor(host: SavedHost?) {
        let alert = NSAlert()
        alert.messageText = host == nil ? L.t("client.hosts.add") : L.t("client.hosts.edit")
        alert.informativeText = L.t("client.hosts.keyHint")
        alert.addButton(withTitle: L.t("common.ok"))
        alert.addButton(withTitle: L.t("common.cancel"))

        let nameField = NSTextField(string: host?.name ?? "")
        nameField.placeholderString = L.t("client.label.hostName")
        let hostField = NSTextField(string: host?.host ?? Prefs.host)
        hostField.placeholderString = L.t("client.label.host")
        let portValue: UInt16 = host?.port ?? UInt16(Prefs.port)
        let portField = NSTextField(string: String(portValue))
        portField.placeholderString = L.t("client.label.port")
        // Concrete resolutions only: no "default" entry, so what you see is what
        // gets saved. Custom sizes are remembered in UserDefaults.
        let resolution = NSPopUpButton(frame: NSRect(x: 90, y: 0, width: 240, height: 25), pullsDown: false)
        let fallback = HostListController.defaultSize
        let current = (host?.width.flatMap { w in host?.height.map { (w, $0) } }) ?? fallback
        var options = HostListController.resolutionOptions()
        if !options.contains(where: { $0.0 == current.0 && $0.1 == current.1 }) {
            options.append(current)
        }
        resolution.addItems(withTitles: options.map { Self.sizeTitle($0) })
        resolution.addItem(withTitle: L.t("client.hosts.addResolution"))
        resolution.selectItem(at: options.firstIndex { $0.0 == current.0 && $0.1 == current.1 } ?? 0)

        // Everything the session window used to carry lives here now: the key,
        // and whether this host gets keyboard/mouse and audio.
        let keyField = NSSecureTextField(string: host?.pskAccount
            .flatMap { HostSecrets.get(account: $0) } ?? "")
        keyField.placeholderString = L.t("client.placeholder.key")
        let inputCheck = NSButton(checkboxWithTitle: L.t("client.check.input"), target: nil, action: nil)
        inputCheck.state = (host?.forwardInput ?? Prefs.forwardInput) ? .on : .off
        let audioCheck = NSButton(checkboxWithTitle: L.t("client.check.audio"), target: nil, action: nil)
        audioCheck.state = (host?.audio ?? Prefs.audio) ? .on : .off
        // Global rather than per host: it is the same two machines on the same
        // link, and a clipboard is a property of the session, not of a display.
        let clipboardCheck = NSButton(checkboxWithTitle: L.t("client.check.clipboard"), target: nil, action: nil)
        clipboardCheck.state = Prefs.clipboard ? .on : .off
        // Colour is per host: it changes what the *server* captures, so it
        // cannot be a global preference shared with a standard-gamut machine.
        let colorPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        colorPopUp.addItems(withTitles: [L.t("client.color.standard"), L.t("client.color.wide")])
        colorPopUp.selectItem(at: (host?.color ?? 0) == ColorMode.wide.rawValue ? 1 : 0)

        // Manual frames: an NSGridView/NSStackView accessory tripped the Swift
        // compiler here ("failed to produce diagnostic"), and this form is fixed
        // size anyway.
        var rows: [(String, NSView)] = [
            (L.t("client.hosts.name"), nameField),
            (L.t("client.label.host"), hostField),
            (L.t("client.label.port"), portField),
            (L.t("client.hosts.resolution"), resolution),
            (L.t("client.label.key"), keyField),
            (L.t("client.hosts.color"), colorPopUp),
        ]
        rows.append(("", inputCheck))
        rows.append(("", audioCheck))
        rows.append(("", clipboardCheck))
        let rowHeight = 32
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: CGFloat(rows.count * rowHeight + 10)))
        let formHeight = form.frame.height
        for (index, row) in rows.enumerated() {
            let y = formHeight - CGFloat((index + 1) * rowHeight) + 2
            if !row.0.isEmpty {
                let label = NSTextField(labelWithString: row.0)
                label.alignment = .right
                label.frame = NSRect(x: 0, y: y + 1, width: 82, height: 22)
                form.addSubview(label)
            }
            let control = row.1
            control.frame = NSRect(x: 90, y: y, width: 250, height: 24)
            form.addSubview(control)
        }
        alert.accessoryView = form

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.isEmpty ? hostField.stringValue : nameField.stringValue
        let port = UInt16(portField.stringValue) ?? 7474
        let selectedIndex = resolution.indexOfSelectedItem
        var size = options[max(0, min(selectedIndex, options.count - 1))]
        if selectedIndex == options.count {
            guard let custom = askForCustomResolution() else { return }
            size = custom
            HostListController.rememberCustomResolution(custom)
        }
        let account = "\(hostField.stringValue):\(port)"
        // Normalise what the user typed: `K7M3-P9QX`, `k7m3 p9qx` and `k7m3p9qx`
        // are the same password, and the file should hold the canonical form.
        let keyText = PSK.isGeneratedPassword(keyField.stringValue)
            ? PSK.normalize(keyField.stringValue)
            : keyField.stringValue
        let hasKey = !keyText.isEmpty
        if hasKey {
            HostSecrets.set(keyText, account: account)
        } else if let old = host?.pskAccount {
            HostSecrets.delete(account: old)
        }
        let keyAccount = hasKey ? account : nil
        let forwardsInput = inputCheck.state == .on
        let playsAudio = audioCheck.state == .on
        Prefs.clipboard = clipboardCheck.state == .on
        let color = colorPopUp.indexOfSelectedItem == 1 ? ColorMode.wide.rawValue : ColorMode.standard.rawValue
        if var existing = host {
            existing.name = name
            existing.host = hostField.stringValue
            existing.port = port
            existing.width = size.0
            existing.height = size.1
            existing.pskAccount = keyAccount
            existing.forwardInput = forwardsInput
            existing.audio = playsAudio
            existing.color = color
            store.update(existing)
        } else {
            store.add(SavedHost(name: name, host: hostField.stringValue, port: port,
                                pskAccount: keyAccount,
                                width: size.0, height: size.1,
                                forwardInput: forwardsInput, audio: playsAudio, color: color))
        }
        reload()
    }
}

extension HostListController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }
}
