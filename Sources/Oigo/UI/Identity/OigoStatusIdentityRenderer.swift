import AppKit
import OigoPresentation

@MainActor
public final class OigoStatusIdentityRenderer {
    public typealias SourceImageProvider = @MainActor () -> NSImage?

    private weak var button: NSButton?
    private var artwork: OigoStatusIdentityArtwork?
    private var animationTimer: Timer?
    private var progressPhase: CGFloat = 0
    private var isShutDown = false
    private let sourceImageProvider: SourceImageProvider

    public init(
        sourceImageProvider: @escaping SourceImageProvider = {
            NSImage(named: NSImage.Name("OigoMenuBar"))
        }
    ) {
        self.sourceImageProvider = sourceImageProvider
    }

    public var activeAnimationCount: Int {
        animationTimer?.isValid == true ? 1 : 0
    }

    public func render(
        _ state: OigoPresentationState,
        on button: NSButton?,
        isVisible: Bool
    ) {
        stopAnimation()
        guard !isShutDown, let button else {
            self.button = nil
            artwork = nil
            return
        }

        let artwork = OigoStatusIdentityArtwork(state: state)
        self.button = button
        self.artwork = artwork
        progressPhase = 0
        apply(artwork, to: button)

        guard artwork.animatesWhenVisible,
              isVisible,
              !button.isHiddenOrHasHiddenAncestor,
              button.window?.isVisible != false else {
            return
        }
        startAnimation()
    }

    public func refreshAppearance() {
        guard !isShutDown, let artwork, let button else { return }
        apply(artwork, to: button)
    }

    public func removeItem() {
        stopAnimation()
        button = nil
        artwork = nil
    }

    public func shutdown() {
        stopAnimation()
        button = nil
        artwork = nil
        isShutDown = true
    }

    private func apply(_ artwork: OigoStatusIdentityArtwork, to button: NSButton) {
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = sourceImageProvider().map {
            artwork.image(
                environment: environment(for: button),
                sourceImage: $0,
                progressPhase: progressPhase
            )
        }
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(artwork.accessibilityLabel)
        button.setAccessibilityValue(artwork.accessibilityValue)
        button.setAccessibilityHelp(artwork.accessibilityHelp)
    }

    private func environment(for button: NSButton) -> OigoStatusIdentityEnvironment {
        let appearance = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        return OigoStatusIdentityEnvironment(
            appearanceName: appearance,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            active: button.isEnabled,
            scaleFactor: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        )
    }

    private func startAnimation() {
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button,
                      !self.isShutDown,
                      let artwork = self.artwork,
                      artwork.animatesWhenVisible,
                      !button.isHiddenOrHasHiddenAncestor,
                      button.window?.isVisible != false else {
                    self?.stopAnimation()
                    return
                }
                self.progressPhase = (self.progressPhase + 0.125).truncatingRemainder(dividingBy: 1)
                self.apply(artwork, to: button)
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}
