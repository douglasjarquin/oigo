import AppKit
import MacUtilityUI

@MainActor
public final class OigoPopoverViewController: NSViewController {
    private enum Metrics {
        static let width: CGFloat = 340
        static let sidePadding: CGFloat = 16
        static let contentWidth: CGFloat = width - (sidePadding * 2)
        static let primaryActionHeight: CGFloat = 30
    }

    private let commandHandler: (OigoPopoverCommand) -> Void
    private let contentStack = NSStackView()
    private var buttonActions: [ObjectIdentifier: OigoPresentationAction] = [:]
    private var inputSelections: [ObjectIdentifier: OigoPopoverInputOption] = [:]
    private var focusableControls: [NSControl] = []
    private var focusTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastPresentation: OigoPopoverPresentation?
    private var lastInputOptions: [OigoPopoverInputOption] = []
    private var controlFailure: String?

    public init(commandHandler: @escaping (OigoPopoverCommand) -> Void) {
        self.commandHandler = commandHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = MacUITokens.Spacing.controlGroup
        contentStack.edgeInsets = NSEdgeInsets(
            top: 13,
            left: Metrics.sidePadding,
            bottom: 12,
            right: Metrics.sidePadding
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Metrics.width),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    public func render(
        _ presentation: OigoPopoverPresentation,
        generation: UInt64,
        inputOptions: [OigoPopoverInputOption]
    ) {
        loadViewIfNeeded()
        self.generation = generation
        lastPresentation = presentation
        lastInputOptions = inputOptions
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        buttonActions.removeAll(keepingCapacity: true)
        inputSelections.removeAll(keepingCapacity: true)
        focusableControls.removeAll(keepingCapacity: true)

        addHeader(presentation)
        addPrimaryAction(presentation.primaryAction)
        addShortcut(presentation.shortcut)
        addDivider()
        addMode(presentation.mode)
        addMicrophone(presentation.microphone, inputOptions: inputOptions)
        if let controlFailure {
            addControlFailure(controlFailure)
        }
        if let notice = presentation.notice {
            addNotice(notice)
        }
        addDivider()
        addLatest(presentation.latest)
        addFooter()
        configureKeyLoop()

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Metrics.width, height: ceil(contentStack.fittingSize.height))
        view.setAccessibilityIdentifier("oigo-popover-content")
        view.setAccessibilityValue(
            "row=" + presentation.row.rawValue
                + ";scroll=" + (presentation.allowsScrolling ? "true" : "false")
        )
    }

    private func addHeader(_ presentation: OigoPopoverPresentation) {
        let title = NSTextField(labelWithString: "Oigo")
        title.font = MacUITokens.Typography.section
        title.textColor = MacUITokens.Colors.primaryLabel
        title.setAccessibilityIdentifier("popover-title")
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("Oigo")
        let status = MacUIStatusBadge(content: statusContent(
            presentation.statusLabel,
            tone: presentation.statusTone
        ), accessibilityIdentifier: "popover-status")
        let row = horizontalRow([title, flexibleSpace(), status])
        row.setAccessibilityIdentifier("popover-header")
        contentStack.addArrangedSubview(row)
    }

    private func addPrimaryAction(_ action: OigoPopoverActionPresentation) {
        let button = NSButton(title: action.title, target: self, action: #selector(performAction(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = MacUITokens.Typography.section
        button.isEnabled = action.isEnabled && action.action != nil
        if let action = action.action {
            buttonActions[ObjectIdentifier(button)] = action
        }
        focusableControls.append(button)
        button.toolTip = action.disabledReason
        button.setAccessibilityIdentifier(
            action.action.map(OigoStatusMenuIdentity.identifier(for:)) ?? "oigo.status.primary-disabled"
        )
        button.setAccessibilityLabel(
            action.action.map(OigoStatusMenuIdentity.accessibilityName(for:)) ?? action.title
        )
        button.heightAnchor.constraint(equalToConstant: Metrics.primaryActionHeight).isActive = true
        button.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        contentStack.addArrangedSubview(button)
    }

    private func addShortcut(_ shortcut: OigoPopoverShortcutPresentation) {
        let hint = NSTextField(labelWithString: shortcut.isAvailable ? "Hold" : "Shortcut")
        hint.font = MacUITokens.Typography.helper
        hint.textColor = MacUITokens.Colors.secondaryLabel
        let glyphs = MacUIShortcutPresentation(
            glyphs: shortcut.glyphs,
            accessibilityLabel: shortcut.accessibilityLabel
        )
        let suffix = NSTextField(labelWithString: shortcut.isAvailable ? "to dictate" : "inactive")
        suffix.font = MacUITokens.Typography.helper
        suffix.textColor = MacUITokens.Colors.secondaryLabel
        let row = horizontalRow([flexibleSpace(), hint, glyphs, suffix, flexibleSpace()])
        row.setAccessibilityIdentifier("popover-shortcut")
        row.setAccessibilityLabel(shortcut.isAvailable ? shortcut.holdHint : shortcut.inactiveHint)
        contentStack.addArrangedSubview(row)
    }

    private func addMode(_ mode: OigoPopoverModePresentation) {
        let label = NSTextField(labelWithString: "Mode")
        label.font = MacUITokens.Typography.label
        label.textColor = MacUITokens.Colors.primaryLabel
        let control = NSSegmentedControl(labels: ["Instant", "Clean"], trackingMode: .selectOne,
                                         target: self, action: #selector(performModeAction(_:)))
        control.selectedSegment = mode.selected == .instant ? 0 : 1
        control.isEnabled = mode.isEnabled
        control.setAccessibilityIdentifier("popover-mode")
        focusableControls.append(control)
        contentStack.addArrangedSubview(horizontalRow([label, flexibleSpace(), control]))
        if mode.appliesToNextDictation {
            let note = MacUIFieldHelpText("Applies to the next dictation")
            note.alignment = .right
            note.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
            contentStack.addArrangedSubview(note)
        }
    }

    private func addMicrophone(
        _ microphone: OigoPopoverMicrophonePresentation,
        inputOptions: [OigoPopoverInputOption]
    ) {
        let label = NSTextField(labelWithString: "Microphone")
        label.font = MacUITokens.Typography.label
        label.textColor = MacUITokens.Colors.primaryLabel
        let value = NSButton(
            title: microphone.label + "  ›",
            target: self,
            action: #selector(showInputMenu(_:))
        )
        value.isBordered = false
        value.alignment = .right
        value.contentTintColor = microphone.tone == .critical || microphone.tone == .warning
            ? MacUITokens.Colors.warning : MacUITokens.Colors.secondaryLabel
        value.isEnabled = microphone.isEnabled && !inputOptions.isEmpty
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focusableControls.append(value)
        let row = horizontalRow([label, flexibleSpace(), value])
        row.setAccessibilityIdentifier("popover-microphone")
        contentStack.addArrangedSubview(row)
    }

    private func addControlFailure(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = MacUITokens.Typography.helper
        label.textColor = MacUITokens.Colors.critical
        label.setAccessibilityIdentifier("popover-control-failure")
        label.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        contentStack.addArrangedSubview(label)
    }

    private func addNotice(_ notice: OigoPopoverNoticePresentation) {
        let card = NSStackView()
        card.orientation = .horizontal
        card.alignment = .top
        card.spacing = MacUITokens.Spacing.controlGroup
        card.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.row,
            left: MacUITokens.Spacing.row,
            bottom: MacUITokens.Spacing.row,
            right: MacUITokens.Spacing.row
        )
        card.wantsLayer = true
        card.layer?.cornerRadius = MacUITokens.Radius.contained
        card.layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityIdentifier("popover-prioritized-notice")
        card.setAccessibilityLabel(notice.title + ". " + notice.body)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: notice.tone == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: notice.title
        ) ?? NSImage())
        icon.contentTintColor = notice.tone == .critical
            ? MacUITokens.Colors.critical : MacUITokens.Colors.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = MacUITokens.Spacing.tight
        let title = NSTextField(labelWithString: notice.title)
        title.font = MacUITokens.Typography.secondary
        title.textColor = MacUITokens.Colors.primaryLabel
        let body = MacUIFieldHelpText(notice.body)
        copy.addArrangedSubview(title)
        copy.addArrangedSubview(body)
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action = NSButton(title: notice.action.title, target: self, action: #selector(performAction(_:)))
        action.bezelStyle = .rounded
        action.controlSize = .small
        action.font = MacUITokens.Typography.secondary
        action.isEnabled = notice.action.isEnabled && notice.action.action != nil
        if let mappedAction = notice.action.action {
            buttonActions[ObjectIdentifier(action)] = mappedAction
            action.setAccessibilityIdentifier(OigoStatusMenuIdentity.identifier(for: mappedAction))
        } else {
            action.setAccessibilityIdentifier("oigo.status.notice-disabled")
        }
        action.setAccessibilityLabel(notice.action.title)
        action.setContentHuggingPriority(.required, for: .horizontal)
        focusableControls.append(action)

        card.addArrangedSubview(icon)
        card.addArrangedSubview(copy)
        card.addArrangedSubview(action)
        card.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        contentStack.addArrangedSubview(card)
    }

    private func addLatest(_ latest: OigoPopoverLatestPresentation?) {
        let heading = NSTextField(labelWithString: "LAST DICTATION")
        heading.font = MacUITokens.Typography.secondary
        heading.textColor = MacUITokens.Colors.secondaryLabel
        heading.setAccessibilityIdentifier("popover-latest-heading")
        if let latest {
            let time = NSTextField(labelWithString: latest.relativeTime)
            time.font = MacUITokens.Typography.secondary
            time.textColor = MacUITokens.Colors.secondaryLabel
            contentStack.addArrangedSubview(horizontalRow([heading, flexibleSpace(), time]))
            let summary = NSTextField(
                labelWithString: [latest.status, latest.duration, latest.source].joined(separator: " · ")
            )
            summary.lineBreakMode = .byTruncatingTail
            summary.maximumNumberOfLines = 1
            summary.setAccessibilityIdentifier("popover-latest-metadata-only")
            summary.font = MacUITokens.Typography.secondary
            summary.textColor = MacUITokens.Colors.primaryLabel
            summary.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
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
            empty.font = MacUITokens.Typography.secondary
            empty.textColor = MacUITokens.Colors.secondaryLabel
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
        button.font = MacUITokens.Typography.secondary
        button.contentTintColor = MacUITokens.Colors.primaryLabel
        buttonActions[ObjectIdentifier(button)] = action
        focusableControls.append(button)
        button.setAccessibilityIdentifier(OigoStatusMenuIdentity.identifier(for: action))
        button.setAccessibilityLabel(OigoStatusMenuIdentity.accessibilityName(for: action))
        button.setAccessibilityRole(.button)
        return button
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        contentStack.addArrangedSubview(divider)
    }

    private func horizontalRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacUITokens.Spacing.controlGroup
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
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

    public func beginPresentation() {
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let first = focusableControls.first else {
                return
            }
            view.window?.makeFirstResponder(first)
            focusTask = nil
        }
    }

    public func showControlFailure(_ message: String) {
        controlFailure = message
        guard let lastPresentation else {
            return
        }
        render(lastPresentation, generation: generation, inputOptions: lastInputOptions)
    }

    public func clearControlFailure() {
        guard controlFailure != nil else {
            return
        }
        controlFailure = nil
        guard let lastPresentation else {
            return
        }
        render(lastPresentation, generation: generation, inputOptions: lastInputOptions)
    }

    public func dismiss() {
        focusTask?.cancel()
        focusTask = nil
        controlFailure = nil
        inputSelections.removeAll()
    }

    private func configureKeyLoop() {
        guard !focusableControls.isEmpty else {
            return
        }
        for (index, control) in focusableControls.enumerated() {
            control.nextKeyView = focusableControls[(index + 1) % focusableControls.count]
        }
    }

    public func moveFocus(_ direction: OigoPopoverFocusDirection) {
        switch direction {
        case .next:
            view.window?.selectNextKeyView(nil)
        case .previous:
            view.window?.selectPreviousKeyView(nil)
        }
    }

    public func invokeFocusedControl() {
        guard let control = view.window?.firstResponder as? NSControl, control.isEnabled else {
            return
        }
        control.performClick(nil)
    }

    @objc private func performAction(_ sender: NSButton) {
        guard let action = buttonActions[ObjectIdentifier(sender)] else {
            return
        }
        commandHandler(OigoPopoverCommand(generation: generation, intent: .presentation(action)))
    }

    @objc private func performModeAction(_ sender: NSSegmentedControl) {
        guard sender.isEnabled else {
            return
        }
        let action: OigoPresentationAction = sender.selectedSegment == 0
            ? .setMode(.instant) : .setMode(.clean)
        commandHandler(OigoPopoverCommand(generation: generation, intent: .presentation(action)))
    }

    @objc private func showInputMenu(_ sender: NSButton) {
        let menu = NSMenu()
        inputSelections.removeAll(keepingCapacity: true)
        for option in lastInputOptions {
            let item = NSMenuItem(title: option.title, action: #selector(selectInput(_:)), keyEquivalent: "")
            item.target = self
            item.state = option.isSelected ? .on : .off
            item.isEnabled = option.isEnabled
            inputSelections[ObjectIdentifier(item)] = option
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY), in: sender)
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let option = inputSelections[ObjectIdentifier(sender)] else {
            return
        }
        commandHandler(OigoPopoverCommand(
            generation: generation,
            intent: .selectInput(option.selection, channel: option.channel)
        ))
    }
}
