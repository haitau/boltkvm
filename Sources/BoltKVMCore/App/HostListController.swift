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

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = L.t("client.hosts.title")
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

        let buttons = NSStackView(views: [add, edit, remove, NSView(), connect])
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
        let detail = NSTextField(labelWithString: "\(host.host):\(host.port)")
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

    private func presentEditor(host: SavedHost?) {
        let alert = NSAlert()
        alert.messageText = host == nil ? L.t("client.hosts.add") : L.t("client.hosts.edit")
        alert.addButton(withTitle: L.t("common.ok"))
        alert.addButton(withTitle: L.t("common.cancel"))

        let nameField = NSTextField(string: host?.name ?? "")
        nameField.placeholderString = L.t("client.label.hostName")
        let hostField = NSTextField(string: host?.host ?? Prefs.host)
        hostField.placeholderString = L.t("client.label.host")
        let portValue: UInt16 = host?.port ?? UInt16(Prefs.port)
        let portField = NSTextField(string: String(portValue))
        portField.placeholderString = L.t("client.label.port")
        // Stored only for now: resolution is a *server* setting until the config
        // packet exists (see docs/plans/2026-10-22-connection-manager-design.md).
        let resolution = NSPopUpButton(frame: NSRect(x: 90, y: 0, width: 220, height: 25), pullsDown: false)
        resolution.addItems(withTitles: ["默认", "1280×720", "1920×1080", "2560×1440", "3008×1692"])
        let sizes: [(Int, Int)?] = [nil, (1280, 720), (1920, 1080), (2560, 1440), (3008, 1692)]
        if let w = host?.width, let h = host?.height,
           let index = sizes.firstIndex(where: { $0?.0 == w && $0?.1 == h }) {
            resolution.selectItem(at: index)
        }

        let preset = NSPopUpButton(frame: NSRect(x: 90, y: 0, width: 220, height: 25), pullsDown: false)
        preset.addItems(withTitles: [L.t("quality.pixel"), L.t("quality.balanced"), L.t("quality.smooth")])
        if let quality = host?.quality {
            preset.selectItem(at: SavedHost.Quality.allCases.firstIndex(of: quality) ?? 0)
        }

        // Manual frames: an NSGridView/NSStackView accessory tripped the Swift
        // compiler here ("failed to produce diagnostic"), and this form is fixed
        // size anyway.
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 162))
        let labels = [L.t("client.hosts.name"), L.t("client.label.host"),
                      L.t("client.label.port"), L.t("client.hosts.resolution"),
                      L.t("client.hosts.quality")]
        let controls: [NSView] = [nameField, hostField, portField, resolution, preset]
        for index in 0..<labels.count {
            let label = NSTextField(labelWithString: labels[index])
            label.alignment = .right
            label.frame = NSRect(x: 0, y: 132 - index * 32, width: 82, height: 22)
            form.addSubview(label)
            let control = controls[index]
            control.frame = NSRect(x: 90, y: 131 - index * 32, width: 240, height: 24)
            form.addSubview(control)
        }
        alert.accessoryView = form

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.isEmpty ? hostField.stringValue : nameField.stringValue
        let port = UInt16(portField.stringValue) ?? 7474
        let quality = SavedHost.Quality.allCases[max(0, preset.indexOfSelectedItem)]
        let size = sizes[max(0, resolution.indexOfSelectedItem)]
        if var existing = host {
            existing.name = name
            existing.host = hostField.stringValue
            existing.port = port
            existing.quality = quality
            existing.width = size?.0
            existing.height = size?.1
            store.update(existing)
        } else {
            store.add(SavedHost(name: name, host: hostField.stringValue, port: port,
                                width: size?.0, height: size?.1, quality: quality))
        }
        reload()
    }
}

extension HostListController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }
}
