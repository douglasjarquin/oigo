import AppKit

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
