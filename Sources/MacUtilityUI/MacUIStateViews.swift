import AppKit

@MainActor
public final class MacUIEmptyStateView: NSStackView {
    public init(message: String, iconRole: MacUIStatusIconRole = .information, accessibilityIdentifier: String? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = MacUITokens.Spacing.controlGroup

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: iconRole.symbolName,
            accessibilityDescription: message
        )
        image.contentTintColor = MacUITokens.Colors.secondaryLabel
        addArrangedSubview(image)

        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = MacUITokens.Colors.secondaryLabel
        label.font = MacUITokens.Typography.body
        addArrangedSubview(label)
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.empty-state", label: message),
            label: message
        )
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

    public init(label: String, accessibilityIdentifier: String? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = MacUITokens.Spacing.controlGroup

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        addArrangedSubview(progressIndicator)

        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = MacUITokens.Colors.secondaryLabel
        labelView.font = MacUITokens.Typography.callout
        addArrangedSubview(labelView)
        MacUIAccessibility.configure(
            self,
            identifier: accessibilityIdentifier ?? MacUIAccessibility.identifier(prefix: "macui.loading", label: label),
            label: label
        )
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
