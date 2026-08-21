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
    case earRecordDot = "ear-record-dot"
    case earAlertDiamond = "ear-alert-diamond"
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
            shapeRole = .earAlertDiamond
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
        progressPhase: CGFloat = 0
    ) -> NSImage {
        let image = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: false
        ) { bounds in
            let draw = {
                Self.draw(
                    in: bounds,
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
            return true
        }
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
        let roleColor: NSColor = switch colorRole {
        case .label: baseColor
        case .accent: NSColor.controlAccentColor.withAlphaComponent(alpha)
        case .recording: NSColor.systemRed.withAlphaComponent(alpha)
        case .attention: NSColor.systemOrange.withAlphaComponent(alpha)
        }

        let ear = NSBezierPath()
        ear.move(to: NSPoint(x: 11.6, y: 15.3))
        ear.curve(
            to: NSPoint(x: 5.0, y: 8.8),
            controlPoint1: NSPoint(x: 7.3, y: 16.1),
            controlPoint2: NSPoint(x: 4.7, y: 13.3)
        )
        ear.curve(
            to: NSPoint(x: 8.0, y: 2.8),
            controlPoint1: NSPoint(x: 5.0, y: 5.8),
            controlPoint2: NSPoint(x: 5.9, y: 2.8)
        )
        ear.curve(
            to: NSPoint(x: 10.8, y: 6.7),
            controlPoint1: NSPoint(x: 10.5, y: 2.8),
            controlPoint2: NSPoint(x: 9.0, y: 5.6)
        )
        ear.curve(
            to: NSPoint(x: 8.3, y: 10.7),
            controlPoint1: NSPoint(x: 12.5, y: 9.5),
            controlPoint2: NSPoint(x: 9.7, y: 11.8)
        )
        ear.lineWidth = lineWidth
        ear.lineCapStyle = .round
        ear.lineJoinStyle = .round
        baseColor.setStroke()
        ear.stroke()

        switch shapeRole {
        case .earOutline:
            break
        case .earProgressRing:
            let ring = NSBezierPath()
            ring.appendArc(
                withCenter: NSPoint(x: 12.8, y: 5.0),
                radius: 2.7,
                startAngle: 35 + progressPhase * 360,
                endAngle: 275 + progressPhase * 360
            )
            ring.lineWidth = lineWidth
            ring.lineCapStyle = .round
            roleColor.setStroke()
            ring.stroke()
        case .earRecordDot:
            let dot = NSBezierPath(ovalIn: NSRect(x: 10.2, y: 2.4, width: 5.2, height: 5.2))
            roleColor.setFill()
            dot.fill()
        case .earAlertDiamond:
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: 12.8, y: 8.3))
            diamond.line(to: NSPoint(x: 16.1, y: 5.0))
            diamond.line(to: NSPoint(x: 12.8, y: 1.7))
            diamond.line(to: NSPoint(x: 9.5, y: 5.0))
            diamond.close()
            diamond.lineWidth = lineWidth
            roleColor.setStroke()
            diamond.stroke()
            let alert = NSBezierPath()
            alert.move(to: NSPoint(x: 12.8, y: 6.5))
            alert.line(to: NSPoint(x: 12.8, y: 4.6))
            alert.move(to: NSPoint(x: 12.8, y: 3.4))
            alert.line(to: NSPoint(x: 12.8, y: 3.35))
            alert.lineWidth = environment.increasedContrast ? 1.9 : 1.45
            alert.lineCapStyle = .round
            roleColor.setStroke()
            alert.stroke()
        }

        _ = bounds
    }
}
