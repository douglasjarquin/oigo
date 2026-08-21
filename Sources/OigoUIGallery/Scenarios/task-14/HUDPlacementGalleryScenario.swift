import AppKit
import Foundation

@MainActor
final class HUDPlacementGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "hud-placement"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        let results = HUDPlacementGalleryResults.load(from: configuration.fixtureRoot)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo HUD Placement - Synthetic Gallery"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = HUDPlacementGalleryViewController(
            configuration: configuration,
            results: results
        )
        return window
    }
}

@MainActor
private final class HUDPlacementGalleryViewController: NSViewController {
    private let configuration: GalleryConfiguration
    private let results: HUDPlacementGalleryResults
    private var captured = false

    init(configuration: GalleryConfiguration, results: HUDPlacementGalleryResults) {
        self.configuration = configuration
        self.results = results
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = HUDPlacementCanvas(
            frame: NSRect(x: 0, y: 0, width: 1120, height: 760),
            results: results
        )
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(
            "Synthetic HUD placement gallery with six deterministic fallback scenarios"
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !captured else { return }
        captured = true
        view.layoutSubtreeIfNeeded()
        captureEvidence()
    }

    private func captureEvidence() {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let imageURL = configuration.evidenceRoot.appendingPathComponent("happy.png")
        try? png.write(to: imageURL, options: .atomic)

        let receipt = results.inspectionReceipt
        let receiptURL = configuration.evidenceRoot.appendingPathComponent("gallery-inspection.json")
        try? Data(receipt.utf8).write(to: receiptURL, options: .atomic)
    }
}

private struct HUDPlacementGalleryResults: Decodable {
    struct Item: Decodable {
        let name: String
        let strategy: String
    }

    let scenario: String
    let fixture: String
    let cases: [Item]
    let captureCalls: Int
    let syntheticAXWrappersCreated: Int
    let syntheticAXWrappersReleased: Int
    let retainedAXObjects: Int
    let pollingTimers: Int
    let coordinateLogs: Int
    let sessionReleased: Bool

    static func load(from fixtureRoot: URL) -> HUDPlacementGalleryResults {
        let url = fixtureRoot.appendingPathComponent("placement-results.json")
        guard let data = try? Data(contentsOf: url),
              let results = try? JSONDecoder().decode(Self.self, from: data),
              results.scenario == "hud-placement",
              results.fixture == "multi-display-negative-origin",
              results.cases.count == 6 else {
            return HUDPlacementGalleryResults(
                scenario: "hud-placement",
                fixture: "unavailable",
                cases: [],
                captureCalls: -1,
                syntheticAXWrappersCreated: -1,
                syntheticAXWrappersReleased: -1,
                retainedAXObjects: -1,
                pollingTimers: -1,
                coordinateLogs: -1,
                sessionReleased: false
            )
        }
        return results
    }

    var inspectionReceipt: String {
        let object: [String: Any] = [
            "scenario": scenario,
            "fixture": fixture,
            "rectangles": cases.count,
            "captureCalls": captureCalls,
            "syntheticAXWrappersCreated": syntheticAXWrappersCreated,
            "syntheticAXWrappersReleased": syntheticAXWrappersReleased,
            "retainedAXObjects": retainedAXObjects,
            "pollingTimers": pollingTimers,
            "coordinateLogs": coordinateLogs,
            "sessionReleased": sessionReleased
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

private final class HUDPlacementCanvas: NSView {
    private struct Card {
        let title: String
        let strategy: String
        let detail: String
        let tone: NSColor
    }

    private let results: HUDPlacementGalleryResults
    private let cards: [Card]

    init(frame frameRect: NSRect, results: HUDPlacementGalleryResults) {
        self.results = results
        cards = results.cases.map(Self.card)
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        drawText(
            "HUD Placement - Synthetic Geometry",
            in: NSRect(x: 36, y: 30, width: 760, height: 34),
            font: .systemFont(ofSize: 26, weight: .bold),
            color: .labelColor
        )
        drawText(
            "Content-free, generation-fenced placement across multiple displays",
            in: NSRect(x: 36, y: 68, width: 760, height: 24),
            font: .systemFont(ofSize: 14),
            color: .secondaryLabelColor
        )
        drawStatusPill()
        drawDisplayDiagram()
        drawCards()
        drawText(
            footerText,
            in: NSRect(x: 36, y: 716, width: 1048, height: 22),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            color: .secondaryLabelColor
        )
    }

    private func drawStatusPill() {
        let frame = NSRect(x: 864, y: 36, width: 220, height: 42)
        let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: 882, y: 51, width: 12, height: 12))
        NSColor.systemGreen.setFill()
        dot.fill()
        drawText(
            String(cards.count) + " contract rectangles",
            in: NSRect(x: 904, y: 47, width: 162, height: 20),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
    }

    private func drawDisplayDiagram() {
        let container = NSRect(x: 36, y: 112, width: 1048, height: 260)
        roundedFill(container, radius: 16, color: .controlBackgroundColor)

        let leftDisplay = NSRect(x: 68, y: 146, width: 448, height: 190)
        let mainDisplay = NSRect(x: 544, y: 162, width: 508, height: 174)
        displayOutline(leftDisplay, title: "Display left of primary", active: true)
        displayOutline(mainDisplay, title: "Main display", active: false)

        let field = NSRect(x: 128, y: 230, width: 170, height: 26)
        roundedFill(field, radius: 6, color: NSColor.systemBlue.withAlphaComponent(0.22))
        stroke(field, radius: 6, color: .systemBlue)
        drawText(
            "Synthetic field",
            in: NSRect(x: 140, y: 234, width: 145, height: 18),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .labelColor
        )

        let hud = NSRect(x: 152, y: 269, width: 228, height: 48)
        roundedFill(hud, radius: 12, color: .windowBackgroundColor)
        shadowedStroke(hud)
        let dot = NSBezierPath(ovalIn: NSRect(x: 170, y: 285, width: 12, height: 12))
        NSColor.systemRed.setFill()
        dot.fill()
        drawText(
            "Recording",
            in: NSRect(x: 192, y: 281, width: 96, height: 20),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )
        drawText(
            "below field",
            in: NSRect(x: 288, y: 282, width: 74, height: 18),
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor
        )
    }

    private func drawCards() {
        let cardWidth: CGFloat = 336
        let cardHeight: CGFloat = 138
        for (index, card) in cards.enumerated() {
            let column = index % 3
            let row = index / 3
            let frame = NSRect(
                x: 36 + CGFloat(column) * (cardWidth + 20),
                y: 394 + CGFloat(row) * (cardHeight + 20),
                width: cardWidth,
                height: cardHeight
            )
            roundedFill(frame, radius: 14, color: .controlBackgroundColor)
            stroke(frame, radius: 14, color: .separatorColor)
            let marker = NSRect(x: frame.minX + 18, y: frame.minY + 20, width: 10, height: 50)
            roundedFill(marker, radius: 5, color: card.tone)
            drawText(
                card.title,
                in: NSRect(x: frame.minX + 44, y: frame.minY + 18, width: 190, height: 22),
                font: .systemFont(ofSize: 14, weight: .semibold),
                color: .labelColor
            )
            drawText(
                card.strategy,
                in: NSRect(x: frame.minX + 44, y: frame.minY + 48, width: 190, height: 24),
                font: .systemFont(ofSize: 18, weight: .bold),
                color: card.tone
            )
            drawText(
                card.detail,
                in: NSRect(x: frame.minX + 44, y: frame.minY + 82, width: 210, height: 20),
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor
            )
            drawText(
                "PASS",
                in: NSRect(x: frame.maxX - 66, y: frame.maxY - 30, width: 48, height: 18),
                font: .monospacedSystemFont(ofSize: 11, weight: .semibold),
                color: .systemGreen
            )
            drawMiniPlacement(item: results.cases[index], in: frame)
        }
    }

    private func drawMiniPlacement(item: HUDPlacementGalleryResults.Item, in card: NSRect) {
        let screen = NSRect(x: card.maxX - 92, y: card.minY + 20, width: 68, height: 58)
        stroke(screen, radius: 5, color: .tertiaryLabelColor)
        let field = NSRect(x: screen.minX + 14, y: screen.minY + 22, width: 30, height: 7)
        let window = NSRect(x: screen.minX + 8, y: screen.minY + 11, width: 52, height: 38)
        if item.strategy == "window-edge" {
            stroke(window, radius: 3, color: .secondaryLabelColor)
        } else if item.strategy == "below-field" || item.strategy == "above-field" {
            roundedFill(field, radius: 2, color: .systemBlue)
        } else if item.name == "display-removal" {
            stroke(
                NSRect(x: screen.minX + 7, y: screen.minY + 8, width: 24, height: 18),
                radius: 3,
                color: .systemPurple
            )
        } else if item.name == "stale-generation" {
            roundedFill(field, radius: 2, color: .tertiaryLabelColor)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: field.minX - 2, y: field.maxY + 2))
            slash.line(to: NSPoint(x: field.maxX + 2, y: field.minY - 2))
            NSColor.systemPink.setStroke()
            slash.lineWidth = 2
            slash.stroke()
        }
        let hudY: CGFloat
        switch item.strategy {
        case "below-field": hudY = field.maxY + 5
        case "above-field": hudY = field.minY - 12
        case "window-edge": hudY = window.maxY - 10
        default: hudY = screen.maxY - 11
        }
        roundedFill(
            NSRect(x: screen.midX - 19, y: hudY, width: 38, height: 8),
            radius: 3,
            color: .labelColor
        )
    }

    private var footerText: String {
        guard cards.count == 6 else { return "Contract results unavailable" }
        return "Synthetic capture calls: \(results.captureCalls)"
            + "  •  AX wrappers: \(results.syntheticAXWrappersCreated)/\(results.syntheticAXWrappersReleased)"
            + "  •  Retained: \(results.retainedAXObjects)"
            + "  •  Polling: \(results.pollingTimers)"
            + "  •  Coordinate logs: \(results.coordinateLogs)"
    }

    private static func card(_ item: HUDPlacementGalleryResults.Item) -> Card {
        switch item.name {
        case "negative-origin-below":
            return Card(title: "Negative-origin display", strategy: title(item.strategy), detail: "Target display preserved", tone: .systemBlue)
        case "edge-field-above":
            return Card(title: "Field near an edge", strategy: title(item.strategy), detail: "Inset-safe horizontal clamp", tone: .systemIndigo)
        case "window-only":
            return Card(title: "Window-only geometry", strategy: title(item.strategy), detail: "No focused element required", tone: .systemTeal)
        case "invalid-geometry":
            return Card(title: "Invalid geometry", strategy: title(item.strategy), detail: "Fallback without failure", tone: .systemOrange)
        case "display-removal":
            return Card(title: "Display removed", strategy: title(item.strategy), detail: "Detached target ignored", tone: .systemPurple)
        default:
            return Card(title: "Stale generation", strategy: title(item.strategy), detail: "Older geometry fenced", tone: .systemPink)
        }
    }

    private static func title(_ strategy: String) -> String {
        strategy.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private func displayOutline(_ frame: NSRect, title: String, active: Bool) {
        roundedFill(frame, radius: 10, color: NSColor.textBackgroundColor.withAlphaComponent(0.5))
        stroke(frame, radius: 10, color: active ? .systemBlue : .separatorColor)
        drawText(
            title,
            in: NSRect(x: frame.minX + 14, y: frame.minY + 12, width: frame.width - 28, height: 18),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )
    }

    private func roundedFill(_ frame: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
    }

    private func stroke(_ frame: NSRect, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        color.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func shadowedStroke(_ frame: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        stroke(frame, radius: 12, color: .separatorColor)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawText(
        _ text: String,
        in frame: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        (text as NSString).draw(
            in: frame,
            withAttributes: [.font: font, .foregroundColor: color]
        )
    }
}
