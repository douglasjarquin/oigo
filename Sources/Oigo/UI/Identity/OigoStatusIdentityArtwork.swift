import AppKit

public enum OigoStatusIdentityVariant: String, Equatable, Sendable {
    case idle
    case processing
    case recording
    case attention
}

public enum OigoStatusIdentityShapeRole: String, Equatable, Sendable {
    case earOutline = "ear-outline"
    case earProgressRing = "ear-progress-ring"
    case earRecordDot = "red-ear-bottom-record-dot"
    case earAttentionDot = "ear-top-attention-dot"
}

public enum OigoStatusIdentityColorRole: String, Equatable, Sendable {
    case label
    case accent
    case recording
    case attention
}

public struct OigoStatusIdentityEnvironment: Sendable {
    public let appearanceName: NSAppearance.Name
    public let increasedContrast: Bool
    public let active: Bool
    public let scaleFactor: CGFloat

    public init(
        appearanceName: NSAppearance.Name,
        increasedContrast: Bool,
        active: Bool,
        scaleFactor: CGFloat
    ) {
        self.appearanceName = appearanceName
        self.increasedContrast = increasedContrast
        self.active = active
        self.scaleFactor = max(1, scaleFactor)
    }

    static let contractAppearances = [
        OigoStatusIdentityEnvironment(
            appearanceName: .aqua,
            increasedContrast: false,
            active: true,
            scaleFactor: 1
        ),
        OigoStatusIdentityEnvironment(
            appearanceName: .darkAqua,
            increasedContrast: false,
            active: true,
            scaleFactor: 1
        ),
        OigoStatusIdentityEnvironment(
            appearanceName: .accessibilityHighContrastAqua,
            increasedContrast: true,
            active: true,
            scaleFactor: 1
        ),
        OigoStatusIdentityEnvironment(
            appearanceName: .aqua,
            increasedContrast: false,
            active: false,
            scaleFactor: 1
        ),
        OigoStatusIdentityEnvironment(
            appearanceName: .darkAqua,
            increasedContrast: true,
            active: true,
            scaleFactor: 2
        )
    ]
}

public struct OigoStatusIdentityArtwork: Equatable, Sendable {
    public let variant: OigoStatusIdentityVariant
    public let shapeRole: OigoStatusIdentityShapeRole
    public let colorRole: OigoStatusIdentityColorRole
    public let isTemplate: Bool
    public let animatesWhenVisible: Bool
    public let accessibilityLabel: String
    public let accessibilityValue: String
    public let accessibilityHelp: String

    public init(state: OigoPresentationState) {
        switch state.menuMark {
        case .activity:
            variant = .processing
            shapeRole = .earProgressRing
            colorRole = .accent
            isTemplate = false
        case .recording:
            variant = .recording
            shapeRole = .earRecordDot
            colorRole = .recording
            isTemplate = false
        case .attention:
            variant = .attention
            shapeRole = .earAttentionDot
            colorRole = .attention
            isTemplate = false
        case .outline, .hidden:
            variant = .idle
            shapeRole = .earOutline
            colorRole = .label
            isTemplate = true
        }

        animatesWhenVisible = variant == .processing
            && state.terminal == nil
            && [.preparing, .finalizing, .cleaning, .inserting].contains(state.status)
        accessibilityLabel = "Oigo"
        accessibilityValue = Self.accessibilityValue(for: state.status)
        accessibilityHelp = Self.accessibilityHelp(for: state.status)
    }

    @MainActor
    public func image(
        environment: OigoStatusIdentityEnvironment,
        sourceImage: NSImage,
        progressPhase: CGFloat = 0
    ) -> NSImage {
        let logicalSize = NSSize(width: 18, height: 18)
        let pixelWidth = Int((logicalSize.width * environment.scaleFactor).rounded())
        let pixelHeight = Int((logicalSize.height * environment.scaleFactor).rounded())
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return NSImage(size: logicalSize)
        }
        representation.size = logicalSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: environment.scaleFactor, y: environment.scaleFactor)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: logicalSize).fill()
        let bounds = NSRect(origin: .zero, size: logicalSize)
        let draw = {
            Self.draw(
                in: bounds,
                sourceImage: sourceImage,
                shapeRole: shapeRole,
                colorRole: colorRole,
                environment: environment,
                progressPhase: progressPhase
            )
        }
        if let appearance = NSAppearance(named: environment.appearanceName) {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.addRepresentation(representation)
        image.isTemplate = isTemplate
        return image
    }

    private static func accessibilityValue(for status: OigoPresentationStatus) -> String {
        switch status {
        case .checking: "Checking"
        case .ready: "Ready"
        case .readyCopyOnly: "Ready, copy only"
        case .attentionNeeded: "Attention needed"
        case .preparing: "Preparing"
        case .recording: "Recording"
        case .finalizing: "Finalizing"
        case .cleaning: "Cleaning"
        case .inserting: "Inserting"
        case .busy: "Busy"
        case .quitting: "Quitting"
        }
    }

    private static func accessibilityHelp(for status: OigoPresentationStatus) -> String {
        switch status {
        case .checking: "Oigo is checking readiness."
        case .ready: "Oigo is ready to start dictation."
        case .readyCopyOnly: "Oigo is ready. Dictation results will be copied."
        case .attentionNeeded: "Oigo needs attention. Open the menu for details."
        case .preparing: "Oigo is preparing dictation."
        case .recording: "Oigo is recording. Stop dictation when finished."
        case .finalizing: "Oigo is finalizing the dictation."
        case .cleaning: "Oigo is cleaning the dictation."
        case .inserting: "Oigo is inserting the dictation."
        case .busy: "Oigo is busy. Open the menu for details."
        case .quitting: "Oigo is quitting."
        }
    }

    @MainActor
    private static func draw(
        in bounds: NSRect,
        sourceImage: NSImage,
        shapeRole: OigoStatusIdentityShapeRole,
        colorRole: OigoStatusIdentityColorRole,
        environment: OigoStatusIdentityEnvironment,
        progressPhase: CGFloat
    ) {
        let alpha: CGFloat = environment.active ? 1 : 0.78
        let requestedLineWidth: CGFloat = environment.increasedContrast ? 2.15 : 1.65
        let devicePixel = 1 / environment.scaleFactor
        let lineWidth = max(
            1.5,
            (requestedLineWidth / devicePixel).rounded() * devicePixel
        )
        let baseColor = NSColor.labelColor.withAlphaComponent(alpha)
        let treatmentColor: NSColor = switch colorRole {
        case .label: baseColor
        case .accent: NSColor.controlAccentColor.withAlphaComponent(alpha)
        case .recording: NSColor.systemRed.withAlphaComponent(alpha)
        case .attention: NSColor.systemOrange.withAlphaComponent(alpha)
        }
        let earColor = shapeRole == .earRecordDot ? treatmentColor : baseColor
        let earRect = NSRect(x: 1.5, y: 0.5, width: 13, height: 17)

        sourceImage.draw(in: earRect)
        earColor.setFill()
        bounds.fill(using: .sourceIn)

        switch shapeRole {
        case .earOutline:
            break
        case .earProgressRing:
            let ring = NSBezierPath()
            ring.appendArc(
                withCenter: NSPoint(x: 14.1, y: 3.2),
                radius: 2.35,
                startAngle: 35 + progressPhase * 360,
                endAngle: 275 + progressPhase * 360
            )
            ring.lineWidth = lineWidth
            ring.lineCapStyle = .round
            treatmentColor.setStroke()
            ring.stroke()
        case .earRecordDot:
            let dot = NSBezierPath(ovalIn: NSRect(x: 12.0, y: 0.6, width: 5.0, height: 5.0))
            treatmentColor.setFill()
            dot.fill()
        case .earAttentionDot:
            let dot = NSBezierPath(ovalIn: NSRect(x: 12.1, y: 12.3, width: 4.8, height: 4.8))
            treatmentColor.setFill()
            dot.fill()
        }
    }
}
