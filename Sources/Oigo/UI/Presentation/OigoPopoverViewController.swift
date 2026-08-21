import AppKit
import MacUtilityUI

@MainActor
public final class OigoPopoverViewController: NSViewController {
    private let actionHandler: (OigoPresentationAction) -> Void
    private let contentStack = NSStackView()
    private var buttonActions: [ObjectIdentifier: OigoPresentationAction] = [:]

    public init(actionHandler: @escaping (OigoPresentationAction) -> Void) {
        self.actionHandler = actionHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    public override func loadView() {
        let root = NSView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    public func render(_ presentation: OigoPopoverPresentation) {
        loadViewIfNeeded()
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        buttonActions.removeAll(keepingCapacity: true)

        addHeader(presentation)
        addPrimaryAction(presentation.primaryAction)
        addShortcut(presentation.shortcut)
        addDivider()
        addMode(presentation.mode)
        addMicrophone(presentation.microphone)
        if let notice = presentation.notice {
            addNotice(notice)
        }
        addDivider()
        addLatest(presentation.latest)
        addFooter()

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 340, height: ceil(contentStack.fittingSize.height))
        view.setAccessibilityIdentifier("oigo-popover-content")
        view.setAccessibilityValue(
            "row=" + presentation.row.rawValue
                + ";scroll=" + (presentation.allowsScrolling ? "true" : "false")
        )
    }

    private func addHeader(_ presentation: OigoPopoverPresentation) {
        let title = NSTextField(labelWithString: "Oigo")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let status = MacUIStatusBadge(content: statusContent(
            presentation.statusLabel,
            tone: presentation.statusTone
        ))
        let row = horizontalRow([title, flexibleSpace(), status])
        row.setAccessibilityIdentifier("popover-header")
        contentStack.addArrangedSubview(row)
    }

    private func addPrimaryAction(_ action: OigoPopoverActionPresentation) {
        let button = NSButton(title: action.title, target: self, action: #selector(performAction(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.isEnabled = action.isEnabled && action.action != nil
        if let action = action.action {
            buttonActions[ObjectIdentifier(button)] = action
        }
        button.toolTip = action.disabledReason
        button.setAccessibilityIdentifier("popover-primary-action")
        button.widthAnchor.constraint(equalToConstant: 308).isActive = true
        contentStack.addArrangedSubview(button)
    }

    private func addShortcut(_ shortcut: OigoPopoverShortcutPresentation) {
        let hint = NSTextField(labelWithString: shortcut.isAvailable ? "Hold" : "Shortcut")
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabelColor
        let glyphs = MacUIShortcutPresentation(
            glyphs: shortcut.glyphs,
            accessibilityLabel: shortcut.accessibilityLabel
        )
        let suffix = NSTextField(labelWithString: shortcut.isAvailable ? "to dictate" : "inactive")
        suffix.font = .preferredFont(forTextStyle: .caption1)
        suffix.textColor = .secondaryLabelColor
        let row = horizontalRow([flexibleSpace(), hint, glyphs, suffix, flexibleSpace()])
        row.setAccessibilityIdentifier("popover-shortcut")
        contentStack.addArrangedSubview(row)
    }

    private func addMode(_ mode: OigoPopoverModePresentation) {
        let label = NSTextField(labelWithString: "Mode")
        let control = NSSegmentedControl(labels: ["Instant", "Clean"], trackingMode: .selectOne,
                                         target: self, action: #selector(performModeAction(_:)))
        control.selectedSegment = mode.selected == .instant ? 0 : 1
        control.isEnabled = mode.isEnabled
        control.setAccessibilityIdentifier("popover-mode")
        contentStack.addArrangedSubview(horizontalRow([label, flexibleSpace(), control]))
        if mode.appliesToNextDictation {
            let note = NSTextField(labelWithString: "Applies to the next dictation")
            note.font = .preferredFont(forTextStyle: .caption1)
            note.textColor = .secondaryLabelColor
            note.alignment = .right
            note.widthAnchor.constraint(equalToConstant: 308).isActive = true
            contentStack.addArrangedSubview(note)
        }
    }

    private func addMicrophone(_ microphone: OigoPopoverMicrophonePresentation) {
        let label = NSTextField(labelWithString: "Microphone")
        let value = NSButton(
            title: microphone.label + "  ›",
            target: self,
            action: #selector(performAction(_:))
        )
        value.isBordered = false
        value.alignment = .right
        value.contentTintColor = microphone.tone == .critical || microphone.tone == .warning
            ? .systemOrange : .secondaryLabelColor
        value.isEnabled = microphone.isEnabled && microphone.action != nil
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let action = microphone.action {
            buttonActions[ObjectIdentifier(value)] = action
        }
        let row = horizontalRow([label, flexibleSpace(), value])
        row.setAccessibilityIdentifier("popover-microphone")
        contentStack.addArrangedSubview(row)
    }

    private func addNotice(_ notice: OigoPopoverNoticePresentation) {
        let view = MacUIInlineNotice(
            content: statusContent(notice.title, tone: notice.tone),
            body: notice.body,
            actionTitle: notice.action.title,
            action: { [actionHandler] in
                guard let action = notice.action.action else { return }
                actionHandler(action)
            }
        )
        view.setAccessibilityIdentifier("popover-prioritized-notice")
        view.widthAnchor.constraint(equalToConstant: 308).isActive = true
        contentStack.addArrangedSubview(view)
    }

    private func addLatest(_ latest: OigoPopoverLatestPresentation?) {
        let heading = NSTextField(labelWithString: "LAST DICTATION")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.setAccessibilityIdentifier("popover-latest-heading")
        if let latest {
            let time = NSTextField(labelWithString: latest.relativeTime)
            time.font = .preferredFont(forTextStyle: .caption1)
            time.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(horizontalRow([heading, flexibleSpace(), time]))
            let summary = NSTextField(
                labelWithString: [latest.status, latest.duration, latest.source].joined(separator: " · ")
            )
            summary.lineBreakMode = .byTruncatingTail
            summary.maximumNumberOfLines = 1
            summary.setAccessibilityIdentifier("popover-latest-metadata-only")
            summary.widthAnchor.constraint(equalToConstant: 308).isActive = true
            contentStack.addArrangedSubview(summary)
            if !latest.actions.isEmpty {
                let actions = NSStackView()
                actions.orientation = .horizontal
                actions.alignment = .centerY
                actions.spacing = 8
                for action in latest.actions {
                    guard let mappedAction = action.action else { continue }
                    let button = footerButton(action.title, action: mappedAction)
                    button.setAccessibilityIdentifier("popover-latest-action-" + mappedAction.category)
                    actions.addArrangedSubview(button)
                }
                if actions.arrangedSubviews.isEmpty == false {
                    contentStack.addArrangedSubview(actions)
                }
            }
        } else {
            contentStack.addArrangedSubview(heading)
            let empty = NSTextField(labelWithString: "No recent dictation")
            empty.textColor = .secondaryLabelColor
            empty.setAccessibilityIdentifier("popover-latest-empty")
            contentStack.addArrangedSubview(empty)
        }
    }

    private func addFooter() {
        let history = footerButton("History…", action: .openHistory)
        let settings = footerButton("Settings…", action: .openSettings)
        let quit = footerButton("Quit Oigo", action: .quit)
        quit.isBordered = false
        let row = horizontalRow([history, settings, flexibleSpace(), quit])
        row.setAccessibilityIdentifier("popover-footer")
        contentStack.addArrangedSubview(row)
    }

    private func footerButton(_ title: String, action: OigoPresentationAction) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
        button.isBordered = false
        buttonActions[ObjectIdentifier(button)] = action
        return button
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 308).isActive = true
        contentStack.addArrangedSubview(divider)
    }

    private func horizontalRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return row
    }

    private func flexibleSpace() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        space.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return space
    }

    private func statusContent(_ label: String, tone: OigoPopoverTone) -> MacUIStatusContent {
        switch tone {
        case .critical:
            .init(tone: .critical, iconRole: .failure, label: label)
        case .warning:
            .init(tone: .warning, iconRole: .attention, label: label)
        case .recording:
            .init(tone: .critical, iconRole: .recording, label: label)
        case .informational:
            .init(tone: .informational, iconRole: .information, label: label)
        case .success:
            .init(tone: .success, iconRole: .confirmation, label: label)
        case .neutral:
            .init(tone: .neutral, iconRole: .information, label: label)
        }
    }

    @objc private func performAction(_ sender: NSButton) {
        guard let action = buttonActions[ObjectIdentifier(sender)] else {
            return
        }
        actionHandler(action)
    }

    @objc private func performModeAction(_ sender: NSSegmentedControl) {
        guard sender.isEnabled else {
            return
        }
        actionHandler(sender.selectedSegment == 0 ? .setMode(.instant) : .setMode(.clean))
    }
}
