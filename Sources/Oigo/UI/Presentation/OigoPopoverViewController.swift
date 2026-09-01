import AppKit
import MacUtilityUI

@MainActor
public final class OigoPopoverViewController: NSViewController {
    private enum Metrics {
        static let width: CGFloat = 340
        static let sidePadding: CGFloat = 16
        static let contentWidth: CGFloat = width - (sidePadding * 2)
        static let primaryActionHeight: CGFloat = 30
        static let footerHeight: CGFloat = 35
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
    private weak var rootView: NSView?
    private var appearanceViews: [(NSView, NSColor)] = []
    private var borderViews: [(NSView, NSColor)] = []

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
        root.layer?.cornerRadius = 11
        root.layer?.masksToBounds = true
        rootView = root
        applyAppearance()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
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

    private func applyAppearance() {
        rootView?.layer?.backgroundColor = Self.popoverBackground.cgColor
        rootView?.layer?.borderColor = Self.shellBorder.cgColor
        rootView?.layer?.borderWidth = 1
        for (view, color) in appearanceViews {
            view.layer?.backgroundColor = color.cgColor
        }
        for (view, color) in borderViews {
            view.layer?.borderColor = color.cgColor
        }
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
        appearanceViews.removeAll(keepingCapacity: true)
        borderViews.removeAll(keepingCapacity: true)

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

        view.effectiveAppearance.performAsCurrentDrawingAppearance { applyAppearance() }
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
        let status = makeStatusLabel(presentation.statusLabel, tone: presentation.statusTone)
        let row = horizontalRow([title, flexibleSpace(), status])
        row.setAccessibilityIdentifier("popover-header")
        contentStack.addArrangedSubview(inset(row, top: 13, left: 16, right: 16))
    }

    private func addPrimaryAction(_ action: OigoPopoverActionPresentation) {
        let button = NSButton(title: action.title, target: self, action: #selector(performAction(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.isEnabled = action.isEnabled && action.action != nil
        let foreground = button.isEnabled ? NSColor.white : MacUITokens.Colors.secondaryLabel
        button.attributedTitle = NSAttributedString(
            string: action.title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: foreground]
        )
        appearanceViews.append((button, primaryBezelColor(for: action)))
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
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .centerX
        section.spacing = 5
        section.addArrangedSubview(button)
        contentStack.addArrangedSubview(inset(section, top: 12, left: 16, right: 16))
    }

    private func addShortcut(_ shortcut: OigoPopoverShortcutPresentation) {
        let hint = NSTextField(labelWithString: shortcut.isAvailable ? "Hold" : "Shortcut")
        hint.font = MacUITokens.Typography.helper
        hint.textColor = MacUITokens.Colors.secondaryLabel
        let glyphs = NSTextField(labelWithString: shortcut.glyphs.joined())
        glyphs.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        glyphs.textColor = MacUITokens.Colors.secondaryLabel
        glyphs.setAccessibilityIdentifier("popover-shortcut-glyphs")
        glyphs.setAccessibilityLabel(shortcut.accessibilityLabel)
        let suffix = NSTextField(labelWithString: shortcut.isAvailable ? "to dictate" : "inactive")
        suffix.font = MacUITokens.Typography.helper
        suffix.textColor = MacUITokens.Colors.secondaryLabel
        let row = horizontalRow([flexibleSpace(), hint, glyphs, suffix, flexibleSpace()])
        row.setAccessibilityIdentifier("popover-shortcut")
        row.setAccessibilityLabel(shortcut.isAvailable ? shortcut.holdHint : shortcut.inactiveHint)
        guard let primarySection = contentStack.arrangedSubviews.last as? NSStackView,
              let inner = primarySection.arrangedSubviews.first as? NSStackView else {
            contentStack.addArrangedSubview(inset(row, left: 16, right: 16))
            return
        }
        inner.addArrangedSubview(row)
    }

    private func addMode(_ mode: OigoPopoverModePresentation) {
        let label = NSTextField(labelWithString: "Mode")
        label.font = MacUITokens.Typography.label
        label.textColor = MacUITokens.Colors.primaryLabel
        let control = makeModeControl(mode)
        control.setAccessibilityIdentifier("popover-mode")
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        section.addArrangedSubview(horizontalRow([label, flexibleSpace(), control]))
        if mode.appliesToNextDictation {
            let note = MacUIFieldHelpText("Applies to the next dictation")
            note.alignment = .right
            note.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
            section.addArrangedSubview(note)
        }
        contentStack.addArrangedSubview(inset(section, top: 10, left: 16, right: 16))
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
        guard let modeWrapper = contentStack.arrangedSubviews.last as? NSStackView,
              let section = modeWrapper.arrangedSubviews.first as? NSStackView else {
            contentStack.addArrangedSubview(inset(row, left: 16, right: 16))
            return
        }
        section.addArrangedSubview(row)
    }

    private func addControlFailure(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = MacUITokens.Typography.helper
        label.textColor = MacUITokens.Colors.critical
        label.setAccessibilityIdentifier("popover-control-failure")
        label.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        contentStack.addArrangedSubview(inset(label, top: 6, left: 16, right: 16))
    }

    private func addNotice(_ notice: OigoPopoverNoticePresentation) {
        let card = NSStackView()
        card.orientation = .horizontal
        card.alignment = .top
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(
            top: 10,
            left: 12,
            bottom: 10,
            right: 12
        )
        card.wantsLayer = true
        card.layer?.cornerRadius = MacUITokens.Radius.contained
        appearanceViews.append((card, Self.noticeBackground))
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityIdentifier("popover-prioritized-notice")
        card.setAccessibilityLabel(notice.title + ". " + notice.body)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: notice.tone == .critical
                ? "xmark.octagon.fill"
                : notice.tone == .informational ? "info.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: notice.title
        ) ?? NSImage())
        icon.contentTintColor = statusColor(for: notice.tone)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 13).isActive = true

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = MacUITokens.Spacing.tight
        let title = NSTextField(labelWithString: notice.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = MacUITokens.Colors.primaryLabel
        let body = MacUIFieldHelpText(notice.body)
        body.font = .systemFont(ofSize: 11.5)
        copy.addArrangedSubview(title)
        copy.addArrangedSubview(body)
        copy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action = NSButton(title: notice.action.title, target: self, action: #selector(performAction(_:)))
        action.isBordered = false
        action.wantsLayer = true
        action.layer?.cornerRadius = 5
        action.layer?.borderWidth = 1
        action.attributedTitle = NSAttributedString(
            string: notice.action.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: MacUITokens.Colors.primaryLabel
            ]
        )
        action.sizeToFit()
        action.widthAnchor.constraint(equalToConstant: min(action.fittingSize.width, 120)).isActive = true
        action.heightAnchor.constraint(equalToConstant: 23).isActive = true
        appearanceViews.append((action, Self.secondaryButtonBackground))
        borderViews.append((action, Self.secondaryButtonBorder))
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
        contentStack.addArrangedSubview(inset(card, top: 12, left: 16, right: 16))
    }

    private func primaryBezelColor(for action: OigoPopoverActionPresentation) -> NSColor {
        guard action.isEnabled, action.action != nil else {
            return MacUITokens.Colors.separator
        }
        if action.action == .stopDictation {
            return MacUITokens.Colors.critical
        }
        return MacUITokens.Colors.accent
    }

    private func makeModeControl(_ mode: OigoPopoverModePresentation) -> NSStackView {
        let instant = modeButton("Instant", tag: 0, selected: mode.selected == .instant, enabled: mode.isEnabled)
        let clean = modeButton("Clean", tag: 1, selected: mode.selected == .clean, enabled: mode.isEnabled)
        let control = NSStackView(views: [instant, clean])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 0
        control.edgeInsets = NSEdgeInsets(top: 1.5, left: 1.5, bottom: 1.5, right: 1.5)
        control.wantsLayer = true
        control.layer?.cornerRadius = 6
        appearanceViews.append((control, Self.modeBackground))
        return control
    }

    private func modeButton(_ title: String, tag: Int, selected: Bool, enabled: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performModeButton(_:)))
        button.tag = tag
        button.isBordered = false
        button.isEnabled = enabled
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.widthAnchor.constraint(equalToConstant: title == "Instant" ? 59 : 55).isActive = true
        button.heightAnchor.constraint(equalToConstant: 21).isActive = true
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: enabled ? MacUITokens.Colors.primaryLabel : MacUITokens.Colors.secondaryLabel
            ]
        )
        if selected {
            appearanceViews.append((button, Self.modeSelectedBackground))
        }
        button.setAccessibilityLabel(title)
        focusableControls.append(button)
        return button
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
            let latestSection = NSStackView()
            latestSection.orientation = .vertical
            latestSection.alignment = .leading
            latestSection.spacing = 6
            latestSection.addArrangedSubview(horizontalRow([heading, flexibleSpace(), time]))
            let summary = NSTextField(
                labelWithString: [latest.status, latest.duration, latest.source].joined(separator: " · ")
            )
            summary.lineBreakMode = .byTruncatingTail
            summary.maximumNumberOfLines = 1
            summary.setAccessibilityIdentifier("popover-latest-metadata-only")
            summary.font = MacUITokens.Typography.secondary
            summary.textColor = MacUITokens.Colors.primaryLabel
            summary.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
            latestSection.addArrangedSubview(summary)
            if !latest.actions.isEmpty {
                let actions = NSStackView()
                actions.orientation = .horizontal
                actions.alignment = .centerY
                actions.spacing = 6
                for action in latest.actions {
                    guard let mappedAction = action.action else { continue }
                    let button = secondaryActionButton(action.title, action: mappedAction)
                    button.setAccessibilityIdentifier("popover-latest-action-" + mappedAction.category)
                    actions.addArrangedSubview(button)
                }
                if actions.arrangedSubviews.isEmpty == false {
                    latestSection.addArrangedSubview(actions)
                }
            }
            contentStack.addArrangedSubview(inset(latestSection, top: 10, left: 16, bottom: 12, right: 16))
        } else {
            let latestSection = NSStackView()
            latestSection.orientation = .vertical
            latestSection.alignment = .leading
            latestSection.spacing = 6
            latestSection.addArrangedSubview(heading)
            let empty = NSTextField(labelWithString: "No recent dictation")
            empty.font = MacUITokens.Typography.secondary
            empty.textColor = MacUITokens.Colors.secondaryLabel
            empty.setAccessibilityIdentifier("popover-latest-empty")
            latestSection.addArrangedSubview(empty)
            contentStack.addArrangedSubview(inset(latestSection, top: 10, left: 16, bottom: 12, right: 16))
        }
    }

    private func addFooter() {
        let history = footerButton("History…", action: .openHistory)
        let settings = footerButton("Settings…", action: .openSettings)
        let quit = footerButton("Quit Oigo", action: .quit)
        quit.isBordered = false
        let row = horizontalRow([history, settings, flexibleSpace(), quit])
        row.setAccessibilityIdentifier("popover-footer")
        let footer = inset(row, top: 9, left: 16, bottom: 9, right: 16)
        footer.wantsLayer = true
        footer.layer?.borderWidth = 0
        footer.heightAnchor.constraint(equalToConstant: Metrics.footerHeight).isActive = true
        appearanceViews.append((footer, Self.footerBackground))
        contentStack.addArrangedSubview(footer)
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

    private func secondaryActionButton(_ title: String, action: OigoPresentationAction) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.borderWidth = 1
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: MacUITokens.Colors.primaryLabel]
        )
        button.sizeToFit()
        button.widthAnchor.constraint(equalToConstant: button.fittingSize.width + 16).isActive = true
        button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        appearanceViews.append((button, Self.secondaryButtonBackground))
        borderViews.append((button, Self.secondaryButtonBorder))
        buttonActions[ObjectIdentifier(button)] = action
        focusableControls.append(button)
        button.setAccessibilityIdentifier(OigoStatusMenuIdentity.identifier(for: action))
        button.setAccessibilityLabel(OigoStatusMenuIdentity.accessibilityName(for: action))
        return button
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        contentStack.addArrangedSubview(inset(divider, top: 12, left: 16, right: 16))
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

    private func inset(
        _ view: NSView,
        top: CGFloat = 0,
        left: CGFloat = 0,
        bottom: CGFloat = 0,
        right: CGFloat = 0
    ) -> NSStackView {
        let wrapper = NSStackView(views: [view])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 0
        wrapper.edgeInsets = NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
        wrapper.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        return wrapper
    }

    private func makeStatusLabel(_ label: String, tone: OigoPopoverTone) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 12)
        text.textColor = statusColor(for: tone)
        text.setAccessibilityIdentifier("popover-status")
        text.setAccessibilityLabel(label)
        guard tone != .neutral && tone != .recording else { return text }
        let symbol: String
        switch tone {
        case .critical: symbol = "xmark.octagon.fill"
        case .warning: symbol = "exclamationmark.triangle.fill"
        case .informational: symbol = "info.circle.fill"
        case .success: symbol = "checkmark.circle.fill"
        case .recording, .neutral: return text
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage())
        icon.contentTintColor = statusColor(for: tone)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.setAccessibilityIdentifier("popover-status")
        row.setAccessibilityLabel(label)
        return row
    }

    private func statusColor(for tone: OigoPopoverTone) -> NSColor {
        switch tone {
        case .critical, .recording: MacUITokens.Colors.critical
        case .warning: MacUITokens.Colors.warning
        case .informational: MacUITokens.Colors.accent
        case .success: MacUITokens.Colors.success
        case .neutral: MacUITokens.Colors.secondaryLabel
        }
    }

    private static let popoverBackground = adaptiveColor(
        light: (244, 244, 246), dark: (44, 44, 48)
    )
    private static let noticeBackground = adaptiveColor(
        light: (232, 232, 235), dark: (57, 57, 61)
    )
    private static let footerBackground = adaptiveColor(
        light: (238, 238, 241), dark: (49, 49, 53)
    )
    private static let modeBackground = adaptiveColor(
        light: (230, 230, 233), dark: (61, 61, 65)
    )
    private static let modeSelectedBackground = adaptiveColor(
        light: (255, 255, 255), dark: (79, 79, 84)
    )
    private static let secondaryButtonBackground = adaptiveColor(
        light: (255, 255, 255), dark: (72, 72, 76)
    )
    private static let secondaryButtonBorder = adaptiveColor(
        light: (206, 206, 210), dark: (99, 99, 104)
    )
    private static let shellBorder = adaptiveColor(
        light: (196, 196, 199), dark: (75, 75, 80)
    )

    private static func adaptiveColor(
        light: (Int, Int, Int),
        dark: (Int, Int, Int)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.name == .darkAqua
                || appearance.name == .accessibilityHighContrastDarkAqua
            let value = isDark ? dark : light
            return NSColor(
                calibratedRed: CGFloat(value.0) / 255,
                green: CGFloat(value.1) / 255,
                blue: CGFloat(value.2) / 255,
                alpha: 1
            )
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

    @objc private func performModeButton(_ sender: NSButton) {
        guard sender.isEnabled else {
            return
        }
        let action: OigoPresentationAction = sender.tag == 0
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
