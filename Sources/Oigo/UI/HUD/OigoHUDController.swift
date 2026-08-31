import AppKit
import Foundation

#if canImport(MacUtilityUI)
import MacUtilityUI
#else
@MainActor
public final class MacUIFloatingPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

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
#endif

public struct OigoHUDResourceSnapshot: Equatable, Sendable {
    public let state: OigoHUDState?
    public let generation: UInt64?
    public let visible: Bool
    public let recordingTimerActive: Bool
    public let dismissalTaskActive: Bool
    public let previewCharacters: Int
    public let sessionReferenceHeld: Bool
    public let recordingTimerStartCount: Int

    public init(
        state: OigoHUDState?,
        generation: UInt64?,
        visible: Bool,
        recordingTimerActive: Bool,
        dismissalTaskActive: Bool,
        previewCharacters: Int,
        sessionReferenceHeld: Bool,
        recordingTimerStartCount: Int
    ) {
        self.state = state
        self.generation = generation
        self.visible = visible
        self.recordingTimerActive = recordingTimerActive
        self.dismissalTaskActive = dismissalTaskActive
        self.previewCharacters = previewCharacters
        self.sessionReferenceHeld = sessionReferenceHeld
        self.recordingTimerStartCount = recordingTimerStartCount
    }
}

public struct OigoHUDRenderInspection: Equatable, Sendable {
    public let state: OigoHUDState?
    public let title: String
    public let detail: String
    public let preview: String
    public let titlePointSize: Double
    public let detailPointSize: Double
    public let previewPointSize: Double
    public let previewIsItalic: Bool
    public let iconRole: OigoHUDIconRole?
    public let iconTreatment: String
    public let symbolName: String
    public let semanticColor: String
    public let size: HUDSize
    public let cornerRadius: Double
    public let renderPasses: Int

    public init(
        state: OigoHUDState?,
        title: String,
        detail: String,
        preview: String,
        titlePointSize: Double,
        detailPointSize: Double,
        previewPointSize: Double,
        previewIsItalic: Bool,
        iconRole: OigoHUDIconRole?,
        iconTreatment: String,
        symbolName: String,
        semanticColor: String,
        size: HUDSize,
        cornerRadius: Double,
        renderPasses: Int
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.preview = preview
        self.titlePointSize = titlePointSize
        self.detailPointSize = detailPointSize
        self.previewPointSize = previewPointSize
        self.previewIsItalic = previewIsItalic
        self.iconRole = iconRole
        self.iconTreatment = iconTreatment
        self.symbolName = symbolName
        self.semanticColor = semanticColor
        self.size = size
        self.cornerRadius = cornerRadius
        self.renderPasses = renderPasses
    }
}

@MainActor
public final class OigoHUDController {
    private let panel: MacUIFloatingPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private var contentView = NSView()
    private var lifecycle = OigoHUDLifecycle()
    private var dismissalTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var previewText = ""
    private var shortcutReleaseHint: String?
    private var sessionReference: AnyObject?
    private var renderRevision: UInt64 = 0
    private var recordingTimerStartCount = 0
    private var lastPlacementInput: HUDPlacementInput?
    private var renderedContent: OigoHUDContent?
    private var renderedSymbolName = ""
    private var renderPasses = 0

    public init() {
        panel = MacUIFloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OigoHUDShellSize.compact.width,
                height: OigoHUDShellSize.compact.height
            )
        )
        configurePanel()
        configureContent()
        panel.orderOut(nil)
    }

    public var canBecomeKey: Bool {
        panel.canBecomeKey
    }

    public var canBecomeMain: Bool {
        panel.canBecomeMain
    }

    public var renderedSize: HUDSize {
        HUDSize(width: Double(panel.contentView?.bounds.width ?? 0), height: Double(panel.contentView?.bounds.height ?? 0))
    }

    public var renderedCornerRadius: Double {
        Double(contentView.layer?.cornerRadius ?? 0)
    }

    public var renderedFrame: HUDRect {
        HUDRect(
            x: Double(panel.frame.origin.x),
            y: Double(panel.frame.origin.y),
            width: Double(panel.frame.width),
            height: Double(panel.frame.height)
        )
    }

    public var renderInspection: OigoHUDRenderInspection? {
        guard let renderedContent else { return nil }
        return OigoHUDRenderInspection(
            state: lifecycle.state,
            title: titleLabel.stringValue,
            detail: detailLabel.stringValue,
            preview: previewText,
            titlePointSize: Double(titleLabel.font?.pointSize ?? 0),
            detailPointSize: Double(detailLabel.font?.pointSize ?? 0),
            previewPointSize: Double(previewLabel.font?.pointSize ?? 0),
            previewIsItalic: previewLabel.font?.fontDescriptor.symbolicTraits.contains(.italic) == true,
            iconRole: renderedContent.iconRole,
            iconTreatment: iconTreatment(for: renderedContent.iconRole),
            symbolName: renderedSymbolName,
            semanticColor: semanticColor(for: renderedContent.tone),
            size: renderedSize,
            cornerRadius: renderedCornerRadius,
            renderPasses: renderPasses
        )
    }

    @discardableResult
    public func captureRenderedSurface(to url: URL) -> Bool {
        guard let view = panel.contentView, view.bounds.width > 0, view.bounds.height > 0 else {
            return false
        }
        panel.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = max(1, panel.backingScaleFactor)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.cgContext.scaleBy(x: scale, y: scale)
        view.layer?.render(in: graphicsContext.cgContext)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public var isVisible: Bool {
        panel.isVisible
    }

    public var resourceSnapshot: OigoHUDResourceSnapshot {
        OigoHUDResourceSnapshot(
            state: lifecycle.state,
            generation: lifecycle.generation,
            visible: lifecycle.visible && panel.isVisible,
            recordingTimerActive: recordingTimer != nil,
            dismissalTaskActive: dismissalTask != nil,
            previewCharacters: previewText.count,
            sessionReferenceHeld: sessionReference != nil,
            recordingTimerStartCount: recordingTimerStartCount
        )
    }

    func task8ShortcutObservation() -> (
        title: String,
        detail: String,
        accessibilityLabel: String,
        visible: Bool
    ) {
        (
            titleLabel.stringValue,
            detailLabel.stringValue,
            contentView.accessibilityLabel() ?? "",
            panel.isVisible
        )
    }

    @discardableResult
    public func present(
        _ state: OigoHUDState,
        generation: UInt64,
        placementInput: HUDPlacementInput? = nil,
        startedAt: Date? = nil,
        sessionReference: AnyObject? = nil,
        shortcutReleaseHint: String
    ) -> Bool {
        guard lifecycle.present(state, generation: generation, visible: true) else {
            return false
        }
        renderRevision &+= 1
        invalidateDismissalTask()
        stopRecordingTimer()
        releaseTransientReferences()

        self.shortcutReleaseHint = shortcutReleaseHint
        let content = OigoHUDShellPolicy.content(
            for: state,
            releaseHint: shortcutReleaseHint,
            preview: previewText
        )
        render(content: content, state: state, startedAt: startedAt)
        if state == .shutdown {
            lifecycle.shutdown()
            releaseTransientReferences()
            lastPlacementInput = nil
            panel.orderOut(nil)
            return true
        }
        self.sessionReference = sessionReference
        lastPlacementInput = placementInput
        applyPlacement(placementInput, size: content.size)
        panel.orderFront(nil)

        if OigoHUDShellPolicy.isRecording(state) {
            recordingStartedAt = startedAt ?? Date()
            startRecordingTimer()
        }
        scheduleDismissal(for: content.dismissal, generation: generation, revision: renderRevision)
        return true
    }

    @discardableResult
    public func updatePreview(
        _ text: String,
        generation: UInt64,
        at time: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> Bool {
        guard lifecycle.generation == generation,
              lifecycle.visible,
              let state = lifecycle.state,
              OigoHUDShellPolicy.allowsPreview(state),
              lifecycle.previewPublicationAllowed(at: time) else {
            return false
        }
        previewText = OigoHUDShellPolicy.boundedPreview(text)
        let content = OigoHUDShellPolicy.content(
            for: state,
            releaseHint: shortcutReleaseHint ?? "",
            preview: previewText
        )
        render(content: content, state: state, startedAt: recordingStartedAt)
        applyPlacement(lastPlacementInput, size: content.size)
        return true
    }

    @discardableResult
    public func hide(generation: UInt64) -> Bool {
        guard lifecycle.hide(generation: generation) else { return false }
        renderRevision &+= 1
        invalidateDismissalTask()
        stopRecordingTimer()
        releaseTransientReferences()
        lastPlacementInput = nil
        panel.orderOut(nil)
        return true
    }

    @discardableResult
    public func stop(generation: UInt64) -> Bool {
        hide(generation: generation)
    }

    @discardableResult
    public func cancel(generation: UInt64, afterDurableRaw: Bool) -> Bool {
        guard lifecycle.generation == generation, let shortcutReleaseHint else { return false }
        let state: OigoHUDState = afterDurableRaw ? .cancelledAfterRaw : .cancelledBeforeRaw
        invalidateOperationResources()
        return present(state, generation: generation, shortcutReleaseHint: shortcutReleaseHint)
    }

    @discardableResult
    public func interrupt(generation: UInt64) -> Bool {
        guard lifecycle.generation == generation, let shortcutReleaseHint else { return false }
        invalidateOperationResources()
        return present(.interrupted, generation: generation, shortcutReleaseHint: shortcutReleaseHint)
    }

    public func shutdown() {
        renderRevision &+= 1
        invalidateOperationResources()
        lastPlacementInput = nil
        lifecycle.shutdown()
        panel.shutdown()
    }

    private func configurePanel() {
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Oigo HUD")
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
    }

    private func configureContent() {
        contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.97)
            .cgColor
        contentView.setAccessibilityRole(.group)
        contentView.setAccessibilityLabel("Oigo HUD status")

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityRole(.staticText)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.preferredMaxLayoutWidth = 274
        detailLabel.setAccessibilityRole(.staticText)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .right
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setAccessibilityRole(.staticText)
        previewLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.maximumNumberOfLines = 2
        previewLabel.preferredMaxLayoutWidth = 274
        previewLabel.setAccessibilityRole(.staticText)

        let titleRow = NSStackView(views: [titleLabel, elapsedLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 10

        let textStack = NSStackView(views: [titleRow, detailLabel, previewLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, textStack])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 11),
            iconView.heightAnchor.constraint(equalToConstant: 11),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            titleRow.trailingAnchor.constraint(equalTo: textStack.trailingAnchor)
        ])
        panel.contentView = contentView
    }

    private func render(
        content: OigoHUDContent,
        state: OigoHUDState,
        startedAt: Date?
    ) {
        renderPasses += 1
        renderedContent = content
        panel.appearance = NSApp.appearance
        contentView.appearance = panel.appearance
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            contentView.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.97)
                .cgColor
        }
        applySize(content.size)
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail
        elapsedLabel.isHidden = !content.showsRecordingElapsed
        previewLabel.isHidden = !content.allowsPreview || previewText.isEmpty
        elapsedLabel.stringValue = content.showsRecordingElapsed
            ? elapsedText(since: startedAt ?? Date()) : ""
        renderedSymbolName = symbolName(for: content.iconRole)
        iconView.image = NSImage(
            systemSymbolName: renderedSymbolName,
            accessibilityDescription: content.title
        )
        iconView.contentTintColor = color(for: content.tone)
        contentView.setAccessibilityLabel(content.title + ". " + content.detail)
        panel.setAccessibilityLabel(content.title + ". " + content.detail)
        renderPreview()
        if state == .shutdown {
            panel.orderOut(nil)
        }
    }

    private func renderPreview() {
        previewLabel.stringValue = previewText.isEmpty ? "" : "\u{201C}" + previewText + "\u{201D}"
        previewLabel.isHidden = previewText.isEmpty || lifecycle.state.map {
            !OigoHUDShellPolicy.allowsPreview($0)
        } ?? true
    }

    private func applySize(_ size: OigoHUDShellSize) {
        let nsSize = NSSize(width: size.width, height: size.height)
        panel.setContentSize(nsSize)
        contentView.setFrameSize(nsSize)
    }

    private func applyPlacement(_ input: HUDPlacementInput?, size: OigoHUDShellSize) {
        let panelSize = HUDSize(width: size.width, height: size.height)
        if let input,
           let placement = HUDPlacement.place(input.withPanelSize(panelSize)),
           placement.generation == input.currentGeneration,
           placement.frame.isValid {
            panel.setFrame(
                NSRect(
                    x: placement.frame.origin.x,
                    y: placement.frame.origin.y,
                    width: placement.frame.size.width,
                    height: placement.frame.size.height
                ),
                display: false
            )
            return
        }

        let visibleFrame = fallbackVisibleFrame(for: input)
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - (panelSize.width / 2),
                y: visibleFrame.minY + 24
            )
        )
    }

    private func fallbackVisibleFrame(for input: HUDPlacementInput?) -> NSRect {
        if let input {
            let preferredIDs = [input.frontmostDisplayID, input.mainDisplayID].compactMap { $0 }
            let display = preferredIDs.compactMap { id in
                input.displays.first { $0.id == id && $0.visibleFrame.isValid }
            }.first ?? input.displays.first(where: { $0.visibleFrame.isValid })
            if let frame = display?.visibleFrame {
                return NSRect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.size.width,
                    height: frame.size.height
                )
            }
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    private func startRecordingTimer() {
        guard lifecycle.recordingTimerActive, panel.isVisible else { return }
        recordingTimerStartCount += 1
        recordingTimer = Timer(
            timeInterval: OigoHUDShellPolicy.recordingTimerInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refreshRecordingTimer()
            }
        }
        if let recordingTimer {
            RunLoop.main.add(recordingTimer, forMode: .common)
        }
    }

    private func refreshRecordingTimer() {
        guard lifecycle.recordingTimerActive,
              panel.isVisible,
              let recordingStartedAt,
              lifecycle.recordingTick(at: Date().timeIntervalSinceReferenceDate) else {
            if !lifecycle.recordingTimerActive || !panel.isVisible {
                stopRecordingTimer()
            }
            return
        }
        elapsedLabel.stringValue = elapsedText(since: recordingStartedAt)
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    private func scheduleDismissal(
        for policy: OigoHUDDismissalPolicy,
        generation: UInt64,
        revision: UInt64
    ) {
        guard policy.kind == .timed, let seconds = policy.seconds else { return }
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.lifecycle.generation == generation,
                  self.renderRevision == revision else {
                return
            }
            _ = self.hide(generation: generation)
        }
    }

    private func invalidateDismissalTask() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    private func invalidateOperationResources() {
        invalidateDismissalTask()
        stopRecordingTimer()
        releaseTransientReferences()
    }

    private func releaseTransientReferences() {
        previewText = ""
        sessionReference = nil
    }

    private func elapsedText(since date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func symbolName(for role: OigoHUDIconRole) -> String {
        switch role {
        case .information:
            "progress.indicator"
        case .confirmation:
            "checkmark"
        case .attention:
            "exclamationmark.triangle.fill"
        case .failure:
            "xmark.octagon.fill"
        case .recording:
            "circle.grid.3x3.fill"
        case .destination:
            "cursorarrow.rays"
        }
    }

    private func iconTreatment(for role: OigoHUDIconRole) -> String {
        switch role {
        case .information:
            "small-spinner"
        case .confirmation:
            "small-check"
        case .recording:
            "nine-dot"
        case .attention:
            "small-attention"
        case .failure:
            "small-failure"
        case .destination:
            "small-destination"
        }
    }

    private func color(for tone: OigoHUDTone) -> NSColor {
        switch tone {
        case .neutral:
            .secondaryLabelColor
        case .informational:
            .controlAccentColor
        case .success:
            .systemGreen
        case .warning:
            .systemOrange
        case .critical:
            .systemRed
        case .recording:
            .systemRed
        }
    }

    private func semanticColor(for tone: OigoHUDTone) -> String {
        switch tone {
        case .neutral:
            "secondary-label"
        case .informational:
            "control-accent"
        case .success:
            "system-green"
        case .warning:
            "system-orange"
        case .critical, .recording:
            "system-red"
        }
    }
}
