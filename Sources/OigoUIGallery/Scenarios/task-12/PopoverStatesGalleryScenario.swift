import AppKit
import OigoPresentation

@MainActor
final class PopoverStatesGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "popover-states"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo Popover States - Synthetic Gallery"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 520)
        window.contentViewController = PopoverStatesGalleryViewController(configuration: configuration)
        return window
    }
}

@MainActor
private final class PopoverStatesGalleryViewController: NSViewController {
    private static let rows = [
        "storage-checking", "storage-ready-idle", "storage-unavailable",
        "shortcut-inactive-conflict", "mic-permission-unavailable",
        "selected-input-unavailable", "language-assets-checking-installing",
        "language-assets-unavailable", "accessibility-unavailable", "preparing", "recording",
        "finalizing-cleaning-inserting", "paste-event-attempted", "paste-owned-field-verified",
        "copied-only", "cleanup-fallback", "insertion-failure", "retry-required",
        "cancelled-before-durable-raw", "cancelled-after-durable-raw", "interrupted",
        "busy-typed-reason", "shutting-down"
    ]

    private let configuration: GalleryConfiguration
    private let stateLabel = NSTextField(labelWithString: "")
    private let card = NSStackView()
    private var selectedRow = "storage-ready-idle"
    private var stateButtons: [NSButton] = []

    init(configuration: GalleryConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Popover state matrix")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.setAccessibilityLabel("Popover state matrix")

        let detail = NSTextField(
            wrappingLabelWithString: "Synthetic metadata only. Select a row to inspect the bounded 340 point popover surface."
        )
        detail.textColor = .secondaryLabelColor

        let rowList = NSStackView()
        rowList.orientation = .vertical
        rowList.alignment = .leading
        rowList.spacing = 4
        for row in Self.rows {
            let button = NSButton(title: row, target: self, action: #selector(selectRow(_:)))
            button.setButtonType(.toggle)
            button.identifier = NSUserInterfaceItemIdentifier(row)
            button.setAccessibilityLabel("Show popover state " + row)
            button.widthAnchor.constraint(equalToConstant: 270).isActive = true
            rowList.addArrangedSubview(button)
            stateButtons.append(button)
        }

        let rowScroll = NSScrollView()
        rowScroll.hasVerticalScroller = true
        rowScroll.autohidesScrollers = false
        rowScroll.drawsBackground = false
        rowScroll.documentView = rowList
        rowScroll.widthAnchor.constraint(equalToConstant: 284).isActive = true

        stateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stateLabel.textColor = .secondaryLabelColor

        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 8
        card.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let preview = NSStackView(views: [stateLabel, card])
        preview.orientation = .vertical
        preview.alignment = .leading
        preview.spacing = 8

        let body = NSStackView(views: [rowScroll, preview])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 20

        let content = NSStackView(views: [title, detail, body])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])
        view = root
        render()
    }

    @objc private func selectRow(_ sender: NSButton) {
        guard let row = sender.identifier?.rawValue else {
            return
        }
        selectedRow = row
        render()
        sender.window?.makeFirstResponder(sender)
    }

    private func render() {
        stateLabel.stringValue = "Synthetic state: " + selectedRow
        for button in stateButtons {
            button.state = button.identifier?.rawValue == selectedRow ? .on : .off
        }
        card.arrangedSubviews.forEach {
            card.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let presentation = Task12PopoverFixture.presentation(rowNamed: selectedRow)
        let header = NSStackView(views: [
            NSTextField(labelWithString: "Oigo"),
            flexibleSpace(),
            NSTextField(labelWithString: presentation.statusLabel)
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        card.addArrangedSubview(header)

        let primary = NSButton(title: presentation.primaryAction.title, target: nil, action: nil)
        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.isEnabled = presentation.primaryAction.isEnabled
        primary.widthAnchor.constraint(equalToConstant: 308).isActive = true
        card.addArrangedSubview(primary)

        let shortcutCopy = presentation.shortcut.isAvailable
            ? presentation.shortcut.holdHint : presentation.shortcut.inactiveHint
        let shortcut = NSTextField(labelWithString: shortcutCopy)
        shortcut.font = .preferredFont(forTextStyle: .caption1)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .center
        shortcut.setAccessibilityLabel(shortcutCopy)
        shortcut.widthAnchor.constraint(equalToConstant: 308).isActive = true
        card.addArrangedSubview(shortcut)

        card.addArrangedSubview(divider())
        let mode = NSSegmentedControl(labels: ["Instant", "Clean"], trackingMode: .selectOne,
                                       target: nil, action: nil)
        mode.selectedSegment = presentation.mode.selected == .instant ? 0 : 1
        mode.isEnabled = presentation.mode.isEnabled
        card.addArrangedSubview(row([NSTextField(labelWithString: "Mode"), flexibleSpace(), mode]))

        let microphone = NSTextField(labelWithString: presentation.microphone.label + "  ›")
        microphone.textColor = .secondaryLabelColor
        card.addArrangedSubview(row([NSTextField(labelWithString: "Microphone"), flexibleSpace(), microphone]))

        if let notice = presentation.notice {
            let noticeView = NSTextField(wrappingLabelWithString: notice.title + ". " + notice.body)
            noticeView.textColor = .secondaryLabelColor
            noticeView.widthAnchor.constraint(equalToConstant: 308).isActive = true
            card.addArrangedSubview(noticeView)
        }

        card.addArrangedSubview(divider())
        let latest = NSTextField(labelWithString: "LAST DICTATION")
        latest.font = .systemFont(ofSize: 11, weight: .semibold)
        latest.textColor = .secondaryLabelColor
        card.addArrangedSubview(latest)
        if let latest = presentation.latest {
            card.addArrangedSubview(NSTextField(
                labelWithString: [latest.status, latest.duration, latest.source].joined(separator: " · ")
            ))
        } else {
            card.addArrangedSubview(NSTextField(labelWithString: "No recent dictation"))
        }

        let footer = row([
            NSButton(title: "History…", target: nil, action: nil),
            NSButton(title: "Settings…", target: nil, action: nil),
            flexibleSpace(),
            NSButton(title: "Quit Oigo", target: nil, action: nil)
        ])
        card.addArrangedSubview(footer)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return stack
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return box
    }

    private func flexibleSpace() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        space.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return space
    }
}
