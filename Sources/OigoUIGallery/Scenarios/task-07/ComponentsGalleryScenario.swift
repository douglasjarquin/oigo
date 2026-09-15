import AppKit
#if canImport(MacUtilityUI)
import MacUtilityUI
#endif

@MainActor
final class ComponentsGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "components"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo Native Components - Synthetic Gallery"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 620)
        window.center()
        window.contentViewController = ComponentsGalleryViewController(configuration: configuration)
        return window
    }
}

@MainActor
private final class ComponentsGalleryViewController: NSViewController {
    private enum Mode: String {
        case normal = "Normal"
        case dark = "Dark"
        case largeText = "Large Text"
        case darkLarge = "Dark + Large Text"
        case reducedMotion = "Reduced Motion"
        case longLabels = "Long Labels"
    }

    private let configuration: GalleryConfiguration
    private let body = NSStackView()
    private let modeLabel = NSTextField(labelWithString: "")
    private let receiptLabel = NSTextField(labelWithString: "No actions invoked")
    private var mode: Mode
    private var loadingView: MacUILoadingView?
    private var transcriptView: MacUITranscriptView?
    private var floatingPanel: MacUIFloatingPanel?
    private var modeButtons: [NSButton] = []
    private var focusButtons: [NSButton] = []
    private var keyboardActivations: [String] = []
    private var keyMonitor: Any?

    init(configuration: GalleryConfiguration) {
        self.configuration = configuration
        self.mode = configuration.appearance == "dark" ? .dark : .normal
        super.init(nibName: nil, bundle: nil)
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = MacUITokens.Spacing.section
        content.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.major,
            left: MacUITokens.Spacing.window,
            bottom: MacUITokens.Spacing.window,
            right: MacUITokens.Spacing.window
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let title = NSTextField(labelWithString: "MacUtilityUI Component Gallery")
        title.font = MacUITokens.Typography.heading
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("MacUtilityUI Component Gallery")
        content.addArrangedSubview(title)

        let safety = NSTextField(
            wrappingLabelWithString: "Synthetic values only - no Oigo data, microphone, permissions, or pasteboard access."
        )
        safety.textColor = MacUITokens.Colors.secondaryLabel
        safety.setAccessibilityLabel(
            "Synthetic values only. No Oigo data, microphone, permissions, or pasteboard access."
        )
        content.addArrangedSubview(safety)

        let modes = NSStackView()
        modes.orientation = .horizontal
        modes.alignment = .centerY
        modes.spacing = MacUITokens.Spacing.controlGroup
        for item in [Mode.normal, .dark, .largeText, .darkLarge, .reducedMotion, .longLabels] {
            let button = NSButton(title: item.rawValue, target: self, action: #selector(changeMode(_:)))
            button.setButtonType(.toggle)
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
            button.setAccessibilityLabel("Show " + item.rawValue + " component scenario")
            button.setContentHuggingPriority(.required, for: .horizontal)
            modes.addArrangedSubview(button)
            modeButtons.append(button)
        }
        content.addArrangedSubview(modes)

        modeLabel.font = MacUITokens.Typography.section
        modeLabel.setAccessibilityRole(.staticText)
        content.addArrangedSubview(modeLabel)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = MacUITokens.Spacing.section
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(body)

        receiptLabel.textColor = .secondaryLabelColor
        receiptLabel.setAccessibilityLabel("Synthetic action receipt")
        content.addArrangedSubview(receiptLabel)

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            body.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -(MacUITokens.Spacing.window * 2))
        ])
        view = root
        renderBody()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyScenarioAppearance()
        updateModeButtonAppearance()
        installKeyboardActivation()
        focusButtons.first?.window?.makeFirstResponder(focusButtons.first)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        shutdownOwnedResources()
    }

    @objc private func changeMode(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let selectedMode = Mode(rawValue: rawValue) else {
            return
        }
        mode = selectedMode
        renderBody()
        if selectedMode == .longLabels {
            sender.window?.setContentSize(NSSize(width: 760, height: 620))
        }
        sender.window?.makeFirstResponder(sender)
    }

    private func renderBody() {
        shutdownOwnedResources()
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        focusButtons.removeAll()

        applyScenarioAppearance()
        for button in modeButtons {
            button.state = button.identifier?.rawValue == mode.rawValue ? .on : .off
            button.setAccessibilityValue(button.state == .on ? "selected" : "not selected")
        }
        updateModeButtonAppearance()
        modeLabel.stringValue = "Scenario: " + mode.rawValue
            + (mode == .reducedMotion ? " - animations terminalized" : "")
        modeLabel.setAccessibilityLabel(modeLabel.stringValue)

        let long = mode == .longLabels
        let readyLabel = long
            ? "Ready with a deliberately long synthetic status label that exercises intrinsic sizing"
            : "Ready"
        let ready = MacUIStatusContent(tone: .success, iconRole: .confirmation, label: readyLabel)
        let warning = MacUIStatusContent(
            tone: .warning,
            iconRole: .attention,
            label: long ? "Synthetic review recommended before continuing this bounded gallery action" : "Review"
        )

        let header = MacUISectionHeader("Status and semantic components")
        header.setAccessibilityRole(.staticText)
        header.setAccessibilityLabel("Status and semantic components")
        body.addArrangedSubview(header)

        let statusRow = MacUIStatusRow(
            content: ready,
            title: long ? "Synthetic component service with an intentionally extended title" : "Synthetic service",
            trailingValue: readyLabel
        )
        statusRow.setAccessibilityRole(.group)
        statusRow.setAccessibilityLabel("Synthetic service, " + readyLabel)
        body.addArrangedSubview(statusRow)

        let badge = MacUIStatusBadge(content: warning)
        badge.setAccessibilityElement(true)
        badge.setAccessibilityRole(.group)
        badge.setAccessibilityLabel(warning.label)
        body.addArrangedSubview(badge)

        let notice = MacUIInlineNotice(
            content: warning,
            body: long
                ? "This deliberately long synthetic notice proves wrapping and intrinsic sizing without loading user content."
                : "Synthetic notice body.",
            actionTitle: "Acknowledge"
        ) { [weak self] in
            self?.record("Inline notice acknowledged")
        }
        let noticeAppearance: NSAppearance?
        if [.dark, .darkLarge].contains(mode) || configuration.appearance == "dark" {
            noticeAppearance = NSAppearance(named: .darkAqua)
        } else if configuration.appearance == "light" || mode == .largeText || mode == .longLabels {
            noticeAppearance = NSAppearance(named: .aqua)
        } else {
            noticeAppearance = nil
        }
        notice.appearance = noticeAppearance
        noticeAppearance?.performAsCurrentDrawingAppearance {
            notice.layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
        }
        notice.setAccessibilityRole(.group)
        notice.setAccessibilityLabel("Synthetic inline notice: " + warning.label)
        notice.arrangedSubviews.first?.setAccessibilityRole(.group)
        body.addArrangedSubview(notice)

        let formHeader = MacUISectionHeader("Forms and health rows")
        formHeader.setAccessibilityRole(.staticText)
        formHeader.setAccessibilityLabel("Forms and health rows")
        body.addArrangedSubview(formHeader)

        let syntheticField = NSTextField(string: "Synthetic value")
        syntheticField.isEditable = false
        syntheticField.isSelectable = false
        syntheticField.setAccessibilityLabel("Synthetic value field")
        let fieldLabel = long ? "Deliberately long synthetic field label" : "Synthetic label"
        let form = MacUIFormRow(
            label: fieldLabel,
            control: syntheticField
        )
        if let label = form.arrangedSubviews.first as? NSTextField {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.setAccessibilityLabel(fieldLabel)
        }
        form.setAccessibilityElement(false)
        body.addArrangedSubview(form)

        let help = MacUIFieldHelpText(
            long
                ? "Long synthetic helper text wraps naturally and remains legible at increased text size."
                : "Synthetic helper text."
        )
        help.setAccessibilityLabel(help.stringValue)
        body.addArrangedSubview(help)

        let permission = MacUIPermissionRow(
            name: "Synthetic permission",
            status: ready,
            actionTitle: "Simulate Permission"
        ) { [weak self] in
            self?.record("Synthetic permission action")
        }
        permission.setAccessibilityRole(.group)
        permission.setAccessibilityLabel("Synthetic permission: " + ready.label)
        permission.arrangedSubviews.first?.setAccessibilityRole(.group)
        body.addArrangedSubview(permission)

        let storage = MacUIStorageHealthRow(
            name: "Synthetic storage",
            status: warning,
            actionTitle: "Simulate Retry"
        ) { [weak self] in
            self?.record("Synthetic storage retry")
        }
        storage.setAccessibilityRole(.group)
        storage.setAccessibilityLabel("Synthetic storage: " + warning.label)
        storage.arrangedSubviews.first?.setAccessibilityRole(.group)
        body.addArrangedSubview(storage)

        let stateHeader = MacUISectionHeader("State, transcript, and lifecycle")
        stateHeader.setAccessibilityRole(.staticText)
        stateHeader.setAccessibilityLabel("State, transcript, and lifecycle")
        body.addArrangedSubview(stateHeader)

        let empty = MacUIEmptyStateView(
            message: long
                ? "No synthetic records exist in this deterministic, content-free gallery state."
                : "No synthetic records"
        )
        empty.setAccessibilityElement(true)
        empty.setAccessibilityRole(.group)
        empty.setAccessibilityLabel("Synthetic empty state")
        body.addArrangedSubview(empty)

        if mode == .reducedMotion {
            let paused = NSTextField(labelWithString: "Loading paused for reduced motion")
            paused.setAccessibilityRole(.staticText)
            paused.setAccessibilityLabel("Loading paused for reduced motion")
            body.addArrangedSubview(paused)
        } else {
            let loading = MacUILoadingView(label: "Loading synthetic state")
            loading.setAccessibilityElement(true)
            loading.setAccessibilityRole(.progressIndicator)
            loading.setAccessibilityLabel("Loading synthetic state")
            loadingView = loading
            body.addArrangedSubview(loading)
        }

        let transcript = MacUITranscriptView(maximumLength: 400)
        transcript.setTranscript(
            "Synthetic transcript specimen. It contains no dictated, copied, or production content."
        )
        transcript.setAccessibilityElement(true)
        transcript.setAccessibilityRole(.textArea)
        transcript.setAccessibilityLabel("Read-only synthetic transcript")
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.heightAnchor.constraint(equalToConstant: mode == .darkLarge ? 132 : 108).isActive = true
        transcriptView = transcript
        body.addArrangedSubview(transcript)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = MacUITokens.Spacing.controlGroup
        let destructive = makeButton(
            title: "Delete Synthetic Item",
            label: "Delete synthetic item",
            action: #selector(showDestructiveConfirmation)
        )
        controls.addArrangedSubview(destructive)
        let clear = makeButton(
            title: "Clear Transcript",
            label: "Clear synthetic transcript",
            action: #selector(clearTranscript)
        )
        controls.addArrangedSubview(clear)
        let stop = makeButton(
            title: "Stop Loading",
            label: "Stop synthetic loading",
            action: #selector(stopLoading)
        )
        stop.isEnabled = loadingView != nil
        controls.addArrangedSubview(stop)
        let panel = makeButton(
            title: "Show Floating Panel",
            label: "Show synthetic floating panel",
            action: #selector(showFloatingPanel)
        )
        controls.addArrangedSubview(panel)
        body.addArrangedSubview(controls)

        let shortcut = MacUIShortcutPresentation(
            glyphs: ["⌘", "⇧", "D"],
            accessibilityLabel: "Command Shift D"
        )
        shortcut.setAccessibilityRole(.group)
        body.addArrangedSubview(shortcut)

        if [.largeText, .darkLarge].contains(mode) {
            applyLargeText(to: body)
        }
        configureFocusOrder(
            in: body,
            destructive: destructive,
            clear: clear,
            stop: stop,
            panel: panel
        )
    }

    private func makeButton(title: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.setAccessibilityLabel(label)
        button.setAccessibilityRole(.button)
        return button
    }

    private func applyScenarioAppearance() {
        let appearance: NSAppearance?
        switch configuration.appearance {
        case "light":
            appearance = NSAppearance(named: .aqua)
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        default:
            appearance = nil
        }
        view.appearance = appearance
        view.window?.appearance = appearance
    }

    private func updateModeButtonAppearance() {
        for button in modeButtons {
            let selected = button.state == .on
            button.wantsLayer = true
            button.layer?.cornerRadius = MacUITokens.Radius.compact
            button.layer?.borderWidth = selected ? 1.5 : 0
            button.layer?.borderColor = selected
                ? MacUITokens.Colors.accent.cgColor
                : NSColor.clear.cgColor
            button.layer?.backgroundColor = selected
                ? MacUITokens.Colors.accent.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
            button.bezelColor = selected
                ? MacUITokens.Colors.accent.withAlphaComponent(0.22)
                : nil
            button.contentTintColor = selected ? MacUITokens.Colors.accent : nil
            button.image = selected
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
                : nil
            button.imagePosition = selected ? .imageLeading : .noImage
        }
    }

    private func configureFocusOrder(
        in root: NSView,
        destructive: NSButton,
        clear: NSButton,
        stop: NSButton,
        panel: NSButton
    ) {
        let buttons = descendants(of: root).compactMap { $0 as? NSButton }
        let notice = buttons.first { $0.title == "Acknowledge" }
        let permission = buttons.first { $0.title == "Simulate Permission" }
        let storage = buttons.first { $0.title == "Simulate Retry" }
        focusButtons = (modeButtons + [notice, permission, storage].compactMap { $0 }
            + [destructive, clear, stop, panel]).filter(\.isEnabled)
        for (current, next) in zip(focusButtons, focusButtons.dropFirst() + focusButtons.prefix(1)) {
            current.nextKeyView = next
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func applyLargeText(to view: NSView) {
        for descendant in [view] + descendants(of: view) {
            if let text = descendant as? NSTextField, let font = text.font {
                text.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 1.28)
            } else if let button = descendant as? NSButton, let font = button.font {
                button.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 1.2)
            }
        }
    }

    private func installKeyboardActivation() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 48 {
                moveFocus(backward: event.modifierFlags.contains(.shift))
                return nil
            }
            guard [36, 49].contains(event.keyCode),
                  let button = event.window?.firstResponder as? NSButton,
                  button.isEnabled else {
                return event
            }
            button.performClick(nil)
            let key = event.keyCode == 36 ? "Return" : "Space"
            keyboardActivations.append(key)
            receiptLabel.stringValue = "Keyboard activations: " + keyboardActivations.joined(separator: ", ")
            receiptLabel.setAccessibilityLabel(receiptLabel.stringValue)
            return nil
        }
    }

    private func moveFocus(backward: Bool) {
        guard let window = view.window, !focusButtons.isEmpty else { return }
        let current = focusButtons.firstIndex { $0 === window.firstResponder }
        let next: Int
        if let current {
            next = (current + (backward ? focusButtons.count - 1 : 1)) % focusButtons.count
        } else {
            next = backward ? focusButtons.count - 1 : 0
        }
        window.makeFirstResponder(focusButtons[next])
    }

    @objc private func showDestructiveConfirmation() {
        guard let window = view.window else { return }
        MacUIDestructiveConfirmation.beginSheet(
            for: window,
            title: "Delete synthetic item?",
            message: "This affects only an in-memory synthetic specimen.",
            confirmTitle: "Delete"
        ) { [weak self] confirmed in
            self?.record(confirmed ? "Synthetic delete confirmed" : "Synthetic delete cancelled")
        }
    }

    @objc private func clearTranscript() {
        transcriptView?.clear()
        record("Synthetic transcript cleared")
    }

    @objc private func stopLoading() {
        let stopped = NSTextField(labelWithString: "Loading stopped")
        stopped.setAccessibilityLabel("Synthetic loading stopped")
        loadingView?.terminalize(replacingWith: stopped)
        loadingView = nil
        record("Synthetic loading stopped")
    }

    @objc private func showFloatingPanel() {
        if let previousPanel = floatingPanel {
            if let parent = previousPanel.parent {
                removeFloatingPanelFromAccessibilityHierarchy(previousPanel, from: parent)
                parent.removeChildWindow(previousPanel)
            }
            previousPanel.terminalize()
        }
        let panel = MacUIFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96))
        panel.title = "Synthetic Nonactivating Panel"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityLabel("Synthetic floating panel window")
        panel.setAccessibilityTitle(panel.title)
        panel.setAccessibilityIdentifier("task7.synthetic.floating-panel")
        panel.isFloatingPanel = true
        let panelContent = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
        panelContent.wantsLayer = true
        panelContent.layer?.backgroundColor = MacUITokens.Colors.windowBackground.cgColor
        panelContent.layer?.cornerRadius = MacUITokens.Radius.floating
        panelContent.layer?.borderWidth = 1
        panelContent.layer?.borderColor = MacUITokens.Colors.separator.cgColor
        panelContent.setAccessibilityElement(true)
        panelContent.setAccessibilityRole(.group)
        panelContent.setAccessibilityLabel("Synthetic floating panel content")
        panelContent.setAccessibilityIdentifier("task7.synthetic.floating-panel.content")
        let label = NSTextField(labelWithString: "Nonactivating - key: false - main: false")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityLabel("Floating panel is nonactivating, non-key, and non-main")
        panelContent.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: panelContent.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: panelContent.centerYAnchor)
        ])
        panel.contentView = panelContent
        panel.setAccessibilityChildren([panelContent])
        if let parent = view.window {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 180, y: frame.maxY - 132))
            panel.setAccessibilityParent(parent)
            parent.setAccessibilityChildren((parent.accessibilityChildren() ?? []) + [panel])
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        floatingPanel = panel
        record("Panel nonactivating=true key=\(panel.canBecomeKey) main=\(panel.canBecomeMain)")
    }

    private func record(_ message: String) {
        receiptLabel.stringValue = message
        receiptLabel.setAccessibilityLabel("Synthetic action receipt: " + message)
    }

    private func shutdownOwnedResources() {
        loadingView?.shutdown()
        loadingView = nil
        transcriptView = nil
        if let panel = floatingPanel, let parent = panel.parent {
            removeFloatingPanelFromAccessibilityHierarchy(panel, from: parent)
            parent.removeChildWindow(panel)
        }
        floatingPanel?.terminalize()
        floatingPanel = nil
    }

    private func removeFloatingPanelFromAccessibilityHierarchy(_ panel: NSPanel, from parent: NSWindow) {
        let remainingChildren = (parent.accessibilityChildren() ?? []).filter {
            ($0 as AnyObject) !== panel
        }
        parent.setAccessibilityChildren(remainingChildren)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
