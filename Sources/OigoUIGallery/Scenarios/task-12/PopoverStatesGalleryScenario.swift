import AppKit
import Foundation
import MacUtilityUI
import OigoCore
import OigoPresentation

@MainActor
final class PopoverStatesGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "popover-states"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
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
    private struct Fixture: Decodable {
        let shortcut: ToggleShortcut
    }

    private struct Observation: Codable {
        let row: String
        let shortcutText: String
        let shortcutAccessibilityLabel: String
        let primaryTitle: String
        let mouseStartEnabled: Bool
        let keyboardAvailable: Bool
        let noticeText: String?
        let noticeActionTitle: String?
        let noticeActionable: Bool
    }

    private struct Receipt: Codable {
        let shortcut: ToggleShortcut
        let selectedRow: String
        let observations: [Observation]
    }

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
    private let committedShortcut: ToggleShortcut
    private let stateLabel = NSTextField(labelWithString: "")
    private let card = NSStackView()
    private var selectedRow = "storage-ready-idle"
    private var stateButtons: [NSButton] = []
    private var renderedPopoverController: OigoPopoverViewController?

    init(configuration: GalleryConfiguration) {
        self.configuration = configuration
        let fixtureURL = configuration.fixtureRoot.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: fixtureURL),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
            preconditionFailure("missing committed shortcut gallery fixture")
        }
        committedShortcut = fixture.shortcut
        selectedRow = fixture.shortcut.keyCode == 255
            ? "shortcut-inactive-conflict" : "storage-ready-idle"
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacUITokens.Colors.windowBackground.cgColor
        let title = NSTextField(labelWithString: "Popover state matrix")
        title.font = MacUITokens.Typography.heading
        title.textColor = MacUITokens.Colors.primaryLabel
        title.setAccessibilityLabel("Popover state matrix")

        let detail = NSTextField(
            wrappingLabelWithString: "Synthetic metadata only. Select a row to inspect the bounded 340 point popover surface."
        )
        detail.font = MacUITokens.Typography.secondary
        detail.textColor = MacUITokens.Colors.secondaryLabel

        let rowList = NSStackView()
        rowList.orientation = .vertical
        rowList.alignment = .leading
        rowList.spacing = 4
        for row in Self.rows {
            let button = NSButton(title: row, target: self, action: #selector(selectRow(_:)))
            button.setButtonType(.toggle)
            button.identifier = NSUserInterfaceItemIdentifier(row)
            button.font = MacUITokens.Typography.secondary
            button.contentTintColor = MacUITokens.Colors.primaryLabel
            button.bezelStyle = .rounded
            button.setAccessibilityLabel("Show popover state " + row)
            button.widthAnchor.constraint(equalToConstant: 270).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            rowList.addArrangedSubview(button)
            stateButtons.append(button)
        }

        rowList.frame = NSRect(x: 0, y: 0, width: 270, height: CGFloat(Self.rows.count * 28))
        let rowScroll = NSScrollView()
        rowScroll.hasVerticalScroller = true
        rowScroll.autohidesScrollers = false
        rowScroll.drawsBackground = false
        rowScroll.documentView = rowList
        rowScroll.widthAnchor.constraint(equalToConstant: 284).isActive = true
        rowScroll.heightAnchor.constraint(equalToConstant: 520).isActive = true

        stateLabel.font = MacUITokens.Typography.secondary
        stateLabel.textColor = MacUITokens.Colors.secondaryLabel

        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = MacUITokens.Spacing.controlGroup
        card.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.row,
            left: MacUITokens.Spacing.section,
            bottom: MacUITokens.Spacing.row,
            right: MacUITokens.Spacing.section
        )
        card.wantsLayer = true
        card.layer?.cornerRadius = MacUITokens.Radius.notice
        card.layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
        card.widthAnchor.constraint(equalToConstant: 340).isActive = true

        let preview = NSStackView(views: [stateLabel, card])
        preview.orientation = .vertical
        preview.alignment = .leading
        preview.spacing = MacUITokens.Spacing.controlGroup

        let body = NSStackView(views: [rowScroll, preview])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 20

        let content = NSStackView(views: [title, detail, body])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = MacUITokens.Spacing.row
        content.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.major,
            left: MacUITokens.Spacing.major,
            bottom: MacUITokens.Spacing.major,
            right: MacUITokens.Spacing.major
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])
        view = root
        let intendedRow = selectedRow
        let healthy = render(rowNamed: "storage-ready-idle")
        let conflict = render(rowNamed: "shortcut-inactive-conflict")
        _ = render(rowNamed: intendedRow)
        writeReceipt(observations: [healthy, conflict])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.render(rowNamed: "shortcut-inactive-conflict")
            self.writeScreenshot(named: "popover-shortcut-conflict.png")
            _ = self.render(rowNamed: intendedRow)
            self.writeScreenshot(named: "popover-states.png")
        }
    }

    @objc private func selectRow(_ sender: NSButton) {
        guard let row = sender.identifier?.rawValue else {
            return
        }
        selectedRow = row
        _ = render(rowNamed: row)
        sender.window?.makeFirstResponder(sender)
    }

    @discardableResult
    private func render(rowNamed rowName: String) -> Observation {
        selectedRow = rowName
        stateLabel.stringValue = "Synthetic state: " + selectedRow
        for button in stateButtons {
            button.state = button.identifier?.rawValue == selectedRow ? .on : .off
        }
        card.arrangedSubviews.forEach {
            card.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let presentation = Task12PopoverFixture.presentation(
            rowNamed: selectedRow,
            committedShortcut: committedShortcut
        )
        let controller = OigoPopoverViewController(commandHandler: { _ in })
        controller.render(presentation, generation: 42, inputOptions: [])
        renderedPopoverController = controller
        let popoverView = controller.view
        popoverView.widthAnchor.constraint(equalToConstant: CGFloat(presentation.width)).isActive = true
        popoverView.heightAnchor.constraint(equalToConstant: controller.preferredContentSize.height).isActive = true
        card.addArrangedSubview(popoverView)
        card.layoutSubtreeIfNeeded()

        guard let shortcut = descendant(identifier: "popover-shortcut", in: popoverView),
              let primary = descendant(
                identifier: presentation.primaryAction.action.map(OigoStatusMenuIdentity.identifier(for:))
                    ?? "oigo.status.primary-disabled",
                in: popoverView
              ) as? NSButton else {
            preconditionFailure("rendered popover shell is missing required controls")
        }
        let notice = descendant(identifier: "popover-prioritized-notice", in: popoverView)
        let noticeAction = notice.flatMap(firstButton(in:))
        return Observation(
            row: selectedRow,
            shortcutText: shortcut.accessibilityLabel() ?? "",
            shortcutAccessibilityLabel: shortcut.accessibilityLabel() ?? "",
            primaryTitle: primary.title,
            mouseStartEnabled: primary.isEnabled,
            keyboardAvailable: presentation.shortcut.isAvailable,
            noticeText: notice?.accessibilityLabel(),
            noticeActionTitle: noticeAction?.title,
            noticeActionable: noticeAction?.isEnabled == true
        )
    }

    @MainActor
    private func descendant(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = descendant(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private func firstButton(in root: NSView) -> NSButton? {
        if let button = root as? NSButton { return button }
        return root.subviews.lazy.compactMap(firstButton(in:)).first
    }

    private func writeReceipt(observations: [Observation]) {
        let receipt = Receipt(
            shortcut: committedShortcut,
            selectedRow: selectedRow,
            observations: observations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(receipt) else {
            preconditionFailure("could not encode shortcut gallery receipt")
        }
        do {
            try data.write(
                to: configuration.evidenceRoot.appendingPathComponent("shortcut-gallery.json"),
                options: .atomic
            )
        } catch {
            preconditionFailure("could not write shortcut gallery receipt")
        }
    }

    private func writeScreenshot(named fileName: String) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("could not allocate popover gallery bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("could not encode popover gallery screenshot")
        }
        do {
            try png.write(
                to: configuration.evidenceRoot.appendingPathComponent(fileName),
                options: .atomic
            )
        } catch {
            preconditionFailure("could not write popover gallery screenshot")
        }
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
