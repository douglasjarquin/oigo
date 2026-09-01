import Foundation

public struct HUDPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct HUDSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        Self.isFiniteCoordinate(width) && Self.isFiniteCoordinate(height)
            && width > 0 && height > 0
    }

    private static func isFiniteCoordinate(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= 10_000_000
    }
}

public struct HUDRect: Equatable, Sendable {
    public let origin: HUDPoint
    public let size: HUDSize

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = HUDPoint(x: x, y: y)
        size = HUDSize(width: width, height: height)
    }

    public static let invalid = HUDRect(x: .nan, y: .nan, width: 0, height: 0)

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + (size.width / 2) }

    public var isValid: Bool {
        Self.isFiniteCoordinate(origin.x) && Self.isFiniteCoordinate(origin.y)
            && size.isValid
            && Self.isFiniteCoordinate(maxX) && Self.isFiniteCoordinate(maxY)
    }

    fileprivate func inset(by amount: Double) -> HUDRect? {
        let result = HUDRect(
            x: minX + amount,
            y: minY + amount,
            width: size.width - (amount * 2),
            height: size.height - (amount * 2)
        )
        return result.isValid ? result : nil
    }

    func intersectionArea(with other: HUDRect) -> Double {
        guard isValid, other.isValid else { return 0 }
        let width = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let height = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        return width * height
    }

    private static func isFiniteCoordinate(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= 10_000_000
    }
}

public struct HUDDisplayGeometry: Equatable, Sendable {
    public let id: UInt32
    public let visibleFrame: HUDRect

    public init(id: UInt32, visibleFrame: HUDRect) {
        self.id = id
        self.visibleFrame = visibleFrame
    }
}

public struct HUDTargetGeometrySnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let captureToken: UUID
    public let fieldFrame: HUDRect?
    public let windowFrame: HUDRect?
    public let targetDisplayID: UInt32?

    public init(
        generation: UInt64,
        captureToken: UUID,
        fieldFrame: HUDRect?,
        windowFrame: HUDRect?,
        targetDisplayID: UInt32?
    ) {
        self.generation = generation
        self.captureToken = captureToken
        self.fieldFrame = fieldFrame?.isValid == true ? fieldFrame : nil
        self.windowFrame = windowFrame?.isValid == true ? windowFrame : nil
        self.targetDisplayID = targetDisplayID
    }
}

public struct HUDPlacementInput: Equatable, Sendable {
    public let snapshot: HUDTargetGeometrySnapshot?
    public let currentGeneration: UInt64
    public let displays: [HUDDisplayGeometry]
    public let frontmostDisplayID: UInt32?
    public let mainDisplayID: UInt32?
    public let panelSize: HUDSize
    public let gap: Double
    public let screenInset: Double

    public init(
        snapshot: HUDTargetGeometrySnapshot?,
        currentGeneration: UInt64,
        displays: [HUDDisplayGeometry],
        frontmostDisplayID: UInt32?,
        mainDisplayID: UInt32?,
        panelSize: HUDSize,
        gap: Double = 10,
        screenInset: Double = 8
    ) {
        self.snapshot = snapshot
        self.currentGeneration = currentGeneration
        self.displays = displays
        self.frontmostDisplayID = frontmostDisplayID
        self.mainDisplayID = mainDisplayID
        self.panelSize = panelSize
        self.gap = gap
        self.screenInset = screenInset
    }

    public func withPanelSize(_ panelSize: HUDSize) -> HUDPlacementInput {
        HUDPlacementInput(
            snapshot: snapshot,
            currentGeneration: currentGeneration,
            displays: displays,
            frontmostDisplayID: frontmostDisplayID,
            mainDisplayID: mainDisplayID,
            panelSize: panelSize,
            gap: gap,
            screenInset: screenInset
        )
    }
}

public enum HUDPlacementStrategy: String, Equatable, Sendable {
    case belowField = "below-field"
    case aboveField = "above-field"
    case windowEdge = "window-edge"
    case screenBottom = "screen-bottom"
    case mainScreen = "main-screen"
    case unavailable
}

public struct HUDPlacementResult: Equatable, Sendable {
    public let frame: HUDRect
    public let strategy: HUDPlacementStrategy
    public let generation: UInt64

    public init(frame: HUDRect, strategy: HUDPlacementStrategy, generation: UInt64) {
        self.frame = frame
        self.strategy = strategy
        self.generation = generation
    }
}

public enum HUDPlacement {
    public static func place(_ input: HUDPlacementInput) -> HUDPlacementResult? {
        guard input.currentGeneration > 0,
              input.panelSize.isValid,
              input.gap.isFinite, input.gap >= 0,
              input.screenInset.isFinite, input.screenInset >= 0 else {
            return nil
        }

        let displays = input.displays.filter { $0.visibleFrame.isValid }
        let currentSnapshot = input.snapshot.flatMap {
            $0.generation == input.currentGeneration && $0.generation > 0 ? $0 : nil
        }
        let mainDisplay = display(input.mainDisplayID, in: displays)

        if let currentSnapshot {
            if let targetID = currentSnapshot.targetDisplayID {
                guard let targetDisplay = display(targetID, in: displays) else {
                    return bottomPlacement(
                        on: mainDisplay,
                        strategy: .mainScreen,
                        input: input
                    )
                }
                if let placed = targetPlacement(
                    snapshot: currentSnapshot,
                    display: targetDisplay,
                    input: input
                ) {
                    return placed
                }
                return bottomPlacement(on: targetDisplay, strategy: .screenBottom, input: input)
            }

            if let resolvedDisplay = geometryDisplay(for: currentSnapshot, in: displays) {
                if let placed = targetPlacement(
                    snapshot: currentSnapshot,
                    display: resolvedDisplay,
                    input: input
                ) {
                    return placed
                }
                return bottomPlacement(on: resolvedDisplay, strategy: .screenBottom, input: input)
            }
        }

        if input.snapshot != nil, currentSnapshot == nil {
            return bottomPlacement(on: mainDisplay, strategy: .mainScreen, input: input)
        }
        if let frontmost = display(input.frontmostDisplayID, in: displays) {
            return bottomPlacement(on: frontmost, strategy: .screenBottom, input: input)
        }
        return bottomPlacement(on: mainDisplay, strategy: .mainScreen, input: input)
    }

    private static func targetPlacement(
        snapshot: HUDTargetGeometrySnapshot,
        display: HUDDisplayGeometry,
        input: HUDPlacementInput
    ) -> HUDPlacementResult? {
        guard let safeFrame = display.visibleFrame.inset(by: input.screenInset),
              safeFrame.size.width >= input.panelSize.width,
              safeFrame.size.height >= input.panelSize.height else {
            return nil
        }

        if let field = snapshot.fieldFrame {
            let x = clamped(
                field.midX - (input.panelSize.width / 2),
                minimum: safeFrame.minX,
                maximum: safeFrame.maxX - input.panelSize.width
            )
            let belowY = field.minY - input.gap - input.panelSize.height
            if belowY >= safeFrame.minY,
               belowY + input.panelSize.height <= safeFrame.maxY {
                return result(x: x, y: belowY, strategy: .belowField, input: input)
            }
            let aboveY = field.maxY + input.gap
            if aboveY >= safeFrame.minY,
               aboveY + input.panelSize.height <= safeFrame.maxY {
                return result(x: x, y: aboveY, strategy: .aboveField, input: input)
            }
        }

        if let window = snapshot.windowFrame {
            let x = clamped(
                window.midX - (input.panelSize.width / 2),
                minimum: safeFrame.minX,
                maximum: safeFrame.maxX - input.panelSize.width
            )
            let y = clamped(
                window.minY + input.screenInset,
                minimum: safeFrame.minY,
                maximum: safeFrame.maxY - input.panelSize.height
            )
            return result(x: x, y: y, strategy: .windowEdge, input: input)
        }
        return nil
    }

    private static func bottomPlacement(
        on display: HUDDisplayGeometry?,
        strategy: HUDPlacementStrategy,
        input: HUDPlacementInput
    ) -> HUDPlacementResult? {
        guard let display,
              let safeFrame = display.visibleFrame.inset(by: input.screenInset),
              safeFrame.size.width >= input.panelSize.width,
              safeFrame.size.height >= input.panelSize.height else {
            return nil
        }
        return result(
            x: safeFrame.midX - (input.panelSize.width / 2),
            y: safeFrame.minY,
            strategy: strategy,
            input: input
        )
    }

    private static func geometryDisplay(
        for snapshot: HUDTargetGeometrySnapshot,
        in displays: [HUDDisplayGeometry]
    ) -> HUDDisplayGeometry? {
        let geometry = snapshot.fieldFrame ?? snapshot.windowFrame
        guard let geometry else { return nil }
        var bestDisplay: HUDDisplayGeometry?
        var bestArea = 0.0
        for display in displays {
            let area = display.visibleFrame.intersectionArea(with: geometry)
            if area > bestArea || (area == bestArea && area > 0 && display.id < (bestDisplay?.id ?? .max)) {
                bestDisplay = display
                bestArea = area
            }
        }
        return bestDisplay
    }

    private static func display(
        _ id: UInt32?,
        in displays: [HUDDisplayGeometry]
    ) -> HUDDisplayGeometry? {
        guard let id else { return nil }
        return displays.first { $0.id == id }
    }

    private static func result(
        x: Double,
        y: Double,
        strategy: HUDPlacementStrategy,
        input: HUDPlacementInput
    ) -> HUDPlacementResult? {
        let frame = HUDRect(
            x: x,
            y: y,
            width: input.panelSize.width,
            height: input.panelSize.height
        )
        guard frame.isValid else { return nil }
        return HUDPlacementResult(
            frame: frame,
            strategy: strategy,
            generation: input.currentGeneration
        )
    }

    private static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}
