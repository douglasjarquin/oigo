#if !canImport(MacUtilityUI)
import AppKit
import Foundation

@MainActor
final class MacUIActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func performAction() {
        action()
    }
}

@MainActor
func makeMacUIActionButton(
    title: String,
    action: @escaping @MainActor () -> Void
) -> (NSButton, MacUIActionTarget) {
    let target = MacUIActionTarget(action: action)
    let button = NSButton(title: title, target: target, action: #selector(MacUIActionTarget.performAction))
    button.bezelStyle = .rounded
    return (button, target)
}

@MainActor
public enum MacUIDestructiveConfirmation {
    public static func makeAlert(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel"
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        confirmButton.hasDestructiveAction = true
        alert.addButton(withTitle: cancelTitle)
        return alert
    }

    public static func beginSheet(
        for window: NSWindow,
        title: String,
        message: String,
        confirmTitle: String,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = makeAlert(title: title, message: message, confirmTitle: confirmTitle)
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}

@MainActor
public final class MacUIFloatingPanel: NSPanel {
    public override var canBecomeKey: Bool {
        false
    }

    public override var canBecomeMain: Bool {
        false
    }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    public func terminalize() {
        orderOut(nil)
        contentView = nil
    }

    public func shutdown() {
        terminalize()
    }
}

@MainActor
public final class MacUIFormRow: NSStackView {
    public init(label: String, control: NSView) {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = .labelColor
        labelView.font = .preferredFont(forTextStyle: .body)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 12
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 128).isActive = true
        addArrangedSubview(labelView)
        addArrangedSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIFieldHelpText: NSTextField {
    public init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        font = .preferredFont(forTextStyle: .caption1)
        textColor = .secondaryLabelColor
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIPermissionRow: NSStackView {
    private let actionTarget: MacUIActionTarget

    public init(
        name: String,
        status: MacUIStatusContent,
        actionTitle: String = "Open System Settings",
        action: @escaping @MainActor () -> Void
    ) {
        let (button, target) = makeMacUIActionButton(title: actionTitle, action: action)
        actionTarget = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        addArrangedSubview(MacUIStatusRow(content: status, title: name, trailingValue: status.label))
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStorageHealthRow: NSStackView {
    private let actionTarget: MacUIActionTarget

    public init(
        name: String,
        status: MacUIStatusContent,
        actionTitle: String = "Retry",
        action: @escaping @MainActor () -> Void
    ) {
        let (button, target) = makeMacUIActionButton(title: actionTitle, action: action)
        actionTarget = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        addArrangedSubview(MacUIStatusRow(content: status, title: name, trailingValue: status.label))
        addArrangedSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

public enum MacUIStatusTone: String, CaseIterable, Sendable {
    case neutral
    case informational
    case success
    case warning
    case critical
    case recording

    @MainActor
    var color: NSColor {
        switch self {
        case .neutral:
            .secondaryLabelColor
        case .informational:
            .controlAccentColor
        case .success:
            .systemGreen
        case .warning:
            .systemOrange
        case .critical, .recording:
            .systemRed
        }
    }
}

public enum MacUIStatusIconRole: String, CaseIterable, Sendable {
    case information
    case confirmation
    case attention
    case failure
    case recording
    case permission
    case storage

    var symbolName: String {
        switch self {
        case .information:
            "info.circle.fill"
        case .confirmation:
            "checkmark.circle.fill"
        case .attention:
            "exclamationmark.triangle.fill"
        case .failure:
            "xmark.octagon.fill"
        case .recording:
            "record.circle.fill"
        case .permission:
            "hand.raised.fill"
        case .storage:
            "internaldrive.fill"
        }
    }
}

public struct MacUIStatusContent: Sendable {
    public let tone: MacUIStatusTone
    public let iconRole: MacUIStatusIconRole
    public let label: String

    public init(tone: MacUIStatusTone, iconRole: MacUIStatusIconRole, label: String) {
        self.tone = tone
        self.iconRole = iconRole
        self.label = label
    }
}

@MainActor
public final class MacUIShortcutPresentation: NSStackView {
    public private(set) var glyphs: [String]

    public init(glyphs: [String], accessibilityLabel: String) {
        self.glyphs = glyphs
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        setAccessibilityElement(true)
        setAccessibilityLabel(accessibilityLabel)
        rebuildGlyphs()
    }

    public func update(glyphs: [String], accessibilityLabel: String) {
        self.glyphs = glyphs
        setAccessibilityLabel(accessibilityLabel)
        rebuildGlyphs()
    }

    private func rebuildGlyphs() {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        for glyph in glyphs {
            let label = NSTextField(labelWithString: glyph)
            label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.alignment = .center
            label.drawsBackground = true
            label.backgroundColor = .controlBackgroundColor
            label.wantsLayer = true
            label.layer?.cornerRadius = 6
            label.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIEmptyStateView: NSStackView {
    public init(message: String, iconRole: MacUIStatusIconRole = .information) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: iconRole.symbolName,
            accessibilityDescription: message
        )
        image.contentTintColor = .secondaryLabelColor
        addArrangedSubview(image)

        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .preferredFont(forTextStyle: .body)
        addArrangedSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUILoadingView: NSStackView {
    private let progressIndicator = NSProgressIndicator()
    private var visibilityObservers: [NSObjectProtocol] = []
    private var isShutdown = false
    public private(set) var isAnimating = false

    public override var isHidden: Bool {
        didSet {
            updateAnimation()
        }
    }

    public init(label: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        addArrangedSubview(progressIndicator)

        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = .secondaryLabelColor
        labelView.font = .preferredFont(forTextStyle: .callout)
        addArrangedSubview(labelView)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeVisibilityObservers()
        if let window {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification
            ] {
                visibilityObservers.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.willCloseNotification {
                            self?.stopAnimation()
                        } else {
                            self?.updateAnimation()
                        }
                    }
                })
            }
        }
        updateAnimation()
    }

    public func terminalize(replacingWith terminalView: NSView? = nil) {
        isShutdown = true
        stopAnimation()
        removeVisibilityObservers()
        if let terminalView, let superview {
            terminalView.translatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
            superview.replaceSubview(self, with: terminalView)
        } else {
            removeFromSuperview()
        }
    }

    public func shutdown() {
        isShutdown = true
        stopAnimation()
        removeVisibilityObservers()
    }

    private func updateAnimation() {
        if !isShutdown,
           window?.isVisible == true,
           window?.isMiniaturized == false,
           window?.occlusionState.contains(.visible) == true,
           !isHiddenOrHasHiddenAncestor {
            progressIndicator.startAnimation(nil)
            isAnimating = true
        } else {
            stopAnimation()
        }
    }

    private func stopAnimation() {
        progressIndicator.stopAnimation(nil)
        isAnimating = false
    }

    private func removeVisibilityObservers() {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        visibilityObservers.removeAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUISectionHeader: NSTextField {
    public init(_ title: String) {
        super.init(frame: .zero)
        stringValue = title
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        textColor = .labelColor
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStatusRow: NSStackView {
    public let content: MacUIStatusContent

    public init(content: MacUIStatusContent, title: String, trailingValue: String? = nil) {
        self.content = content
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: content.iconRole.symbolName,
            accessibilityDescription: content.label
        )
        image.contentTintColor = content.tone.color
        image.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(image)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        addArrangedSubview(titleLabel)

        if let trailingValue {
            let valueLabel = NSTextField(labelWithString: trailingValue)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.alignment = .right
            valueLabel.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(valueLabel)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("\(title), \(content.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIStatusBadge: NSStackView {
    public let content: MacUIStatusContent

    public init(content: MacUIStatusContent) {
        self.content = content
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: content.iconRole.symbolName,
            accessibilityDescription: content.label
        )
        icon.contentTintColor = content.tone.color
        addArrangedSubview(icon)

        let label = NSTextField(labelWithString: content.label)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = content.tone.color
        addArrangedSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUIInlineNotice: NSStackView {
    public let content: MacUIStatusContent
    private var actionTarget: MacUIActionTarget?

    public init(
        content: MacUIStatusContent,
        body: String,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.content = content
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        addArrangedSubview(MacUIStatusRow(content: content, title: content.label))
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.font = .preferredFont(forTextStyle: .callout)
        addArrangedSubview(bodyLabel)

        if let actionTitle, let action {
            let (button, target) = makeMacUIActionButton(title: actionTitle, action: action)
            actionTarget = target
            addArrangedSubview(button)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
public final class MacUITranscriptView: NSScrollView {
    private let textView: NSTextView
    public let maximumLength: Int
    public var transcript: String {
        textView.string
    }

    public init(maximumLength: Int = 20_000) {
        self.maximumLength = max(1, maximumLength)
        textView = NSTextView(frame: .zero)
        super.init(frame: .zero)

        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        drawsBackground = true
        documentView = textView

        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
    }

    public func setTranscript(_ transcript: String) {
        textView.string = String(transcript.prefix(maximumLength))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    public func clear() {
        textView.string = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
#endif
