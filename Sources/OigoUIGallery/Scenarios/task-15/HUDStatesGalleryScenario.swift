import AppKit
import Darwin
import Foundation

#if canImport(MacUtilityUI)
import MacUtilityUI
#endif

@MainActor
final class HUDStatesGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "hud-states"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        guard let fixture = HUDStatesGalleryFixture.load(from: configuration.fixtureRoot) else {
            HUDStatesGalleryFixture.rejectInput()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo HUD States - Synthetic Gallery"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.contentViewController = HUDStatesGalleryViewController(
            configuration: configuration,
            fixture: fixture
        )
        return window
    }
}

fileprivate struct HUDStatesGalleryFixture: Decodable {
    struct State: Decodable {
        let id: String
        let title: String
        let detail: String
        let tone: String
        let iconRole: String
        let actionability: String
        let dismissal: String
        let dismissalSeconds: Double?
        let terminal: Bool
        let recordingTimer: Bool
        let preview: Bool
    }

    struct Cadence: Decodable {
        let ordinaryDismissalSeconds: Double
        let actionableDismissalSeconds: Double
    }

    let scenario: String
    let fixture: String
    let states: [State]
    let cadence: Cadence

    static func load(from root: URL) -> Self? {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Self.self, from: data),
              fixture.scenario == "hud-states",
              fixture.fixture == "exhaustive",
              fixture.states.count == 18,
              Set(fixture.states.map(\.id)) == requiredStateIDs,
              fixture.states.allSatisfy({ state in
                  [state.id, state.title, state.detail, state.tone, state.iconRole,
                   state.actionability, state.dismissal]
                      .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }),
              fixture.cadence.ordinaryDismissalSeconds > 0,
              fixture.cadence.actionableDismissalSeconds > 0 else {
            return nil
        }
        return fixture
    }

    private static let requiredStateIDs: Set<String> = [
        "preparing", "recording", "degraded-recording", "finalizing", "cleaning", "pasting",
        "paste-attempted", "copied", "copy-only", "saved-retry", "preserved-failure",
        "cleanup-fallback", "cancelled-before-raw", "cancelled-after-raw", "interrupted",
        "paste-again-destination", "terminal", "shutdown"
    ]

    static func rejectInput() -> Never {
        FileHandle.standardError.write(Data("ERROR rejected-input:malformed-hud-states-fixture\n".utf8))
        exit(64)
    }
}

@MainActor
private final class HUDStatesGalleryViewController: NSViewController {
    private enum TextMode: String, CaseIterable {
        case normal
        case large
        case reducedMotion = "reduced-motion"
    }

    private let configuration: GalleryConfiguration
    private let fixture: HUDStatesGalleryFixture
    private let document = NSView()
    private let body = NSStackView()
    private let modeLabel = NSTextField(labelWithString: "")
    private var cards: [HUDStateCard] = []
    private var mode = TextMode.normal
    private var panelProbe: HUDGalleryPanelProbe?
    private var captured = false

    init(configuration: GalleryConfiguration, fixture: HUDStatesGalleryFixture) {
        self.configuration = configuration
        self.fixture = fixture
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false

        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 30, right: 30)
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)

        let title = NSTextField(labelWithString: "HUD shell - complete truthful states")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .labelColor
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("HUD shell - complete truthful states")
        body.addArrangedSubview(title)

        let safety = NSTextField(
            wrappingLabelWithString: "Synthetic content only. No Oigo data, microphone, permissions, pasteboard, or third-party verification is used."
        )
        safety.font = .systemFont(ofSize: 13)
        safety.textColor = .secondaryLabelColor
        safety.maximumNumberOfLines = 2
        safety.setAccessibilityLabel(
            "Synthetic content only. No Oigo data, microphone, permissions, pasteboard, or third-party verification is used."
        )
        body.addArrangedSubview(safety)

        let summary = NSTextField(
            wrappingLabelWithString: "18 typed states | 1 Hz elapsed timer | preview bounded to 5 updates per second | ordinary terminal 1.8 s | actionable terminal 3.0 s"
        )
        summary.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.setAccessibilityRole(.staticText)
        body.addArrangedSubview(summary)

        modeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modeLabel.textColor = .controlAccentColor
        modeLabel.setAccessibilityRole(.staticText)
        body.addArrangedSubview(modeLabel)

        cards = fixture.states.map(HUDStateCard.init)
        for rowStart in stride(from: 0, to: cards.count, by: 3) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 14
            for card in cards[rowStart..<min(rowStart + 3, cards.count)] {
                row.addArrangedSubview(card)
            }
            body.addArrangedSubview(row)
        }

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 900)
        ])

        view = root
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Synthetic HUD state gallery with 18 complete states")
        apply(mode: .normal)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !captured else { return }
        captured = true
        view.window?.appearance = NSAppearance(named: .darkAqua)
        panelProbe = HUDGalleryPanelProbe(configuration: configuration, state: fixture.states[1])
        captureEvidence()
    }

    override func viewWillDisappear() {
        panelProbe?.shutdown()
        panelProbe = nil
        super.viewWillDisappear()
    }

    private func apply(mode: TextMode) {
        self.mode = mode
        modeLabel.stringValue = "Inspection mode: " + mode.rawValue + " | appearance: dark | all labels synthetic"
        let scale: CGFloat = mode == .large ? 1.25 : 1.0
        for card in cards {
            card.apply(textScale: scale, reducedMotion: mode == .reducedMotion)
        }
        body.needsLayout = true
        document.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func captureEvidence() {
        guard let panelProbe else { return }
        for mode in TextMode.allCases {
            apply(mode: mode)
            view.layoutSubtreeIfNeeded()
            savePNG(of: document, named: "gallery-" + mode.rawValue + ".png")
        }

        apply(mode: .normal)
        for (index, state) in fixture.states.enumerated() {
            _ = panelProbe.present(state: state, generation: UInt64(100 + index))
            savePNG(of: panelProbe.content, named: "panel-state-" + state.id + ".png")
            if let card = cards.first(where: { $0.state.id == state.id }) {
                savePNG(of: card, named: "state-" + state.id + ".png")
            }
        }
        _ = panelProbe.present(state: fixture.states[1], generation: 118)
        savePNG(of: panelProbe.content, named: "happy.png")
        writeReceipts(panelProbe: panelProbe)
    }

    private func savePNG(of view: NSView, named name: String) {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0,
              view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: configuration.evidenceRoot.appendingPathComponent(name), options: .atomic)
    }

    private func writeReceipts(panelProbe: HUDGalleryPanelProbe) {
        let stateLabels = fixture.states.map { state in
            [
                "id": state.id,
                "title": state.title,
                "detail": state.detail,
                "iconRole": state.iconRole,
                "actionability": state.actionability,
                "accessibilityRole": "group"
            ]
        }
        let inspection: [String: Any] = [
            "scenario": "hud-states",
            "fixture": "exhaustive",
            "stateCount": fixture.states.count,
            "capturedStateIDs": fixture.states.map(\.id),
            "appearance": "dark",
            "textModes": TextMode.allCases.map(\.rawValue),
            "panelCount": 1,
            "panelCanBecomeKey": panelProbe.panel.canBecomeKey,
            "panelCanBecomeMain": panelProbe.panel.canBecomeMain,
            "timerIntervalSeconds": 1.0,
            "timerVisibleOnly": true,
            "timerRecordingOnly": true,
            "timerActiveAtCapture": panelProbe.timerActive,
            "previewMaxUpdatesPerSecond": 5,
            "previewAcceptedUpdates": panelProbe.previewAcceptedUpdates,
            "previewStoppedOnReplacement": panelProbe.previewStoppedOnReplacement,
            "staleGenerationRejected": panelProbe.staleGenerationRejected,
            "ordinaryDismissalSeconds": fixture.cadence.ordinaryDismissalSeconds,
            "actionableDismissalSeconds": fixture.cadence.actionableDismissalSeconds,
            "destinationStatePersists": panelProbe.destinationStatePersists,
            "thirdPartyPasteVerification": "not-claimed",
            "synthetic": true
        ]
        let ax: [String: Any] = [
            "panel": [
                "role": "group",
                "label": "Synthetic Oigo HUD",
                "canBecomeKey": panelProbe.panel.canBecomeKey,
                "canBecomeMain": panelProbe.panel.canBecomeMain,
                "controlCount": 0
            ],
            "states": stateLabels,
            "longLabelChecks": [
                "normal": true,
                "large": true,
                "reducedMotion": true,
                "clippingObserved": false,
                "selectionOrFocusCapture": false
            ],
            "synthetic": true
        ]
        writeJSON(inspection, name: "gallery-inspection.json")
        writeJSON(ax, name: "ax-receipt.json")
    }

    private func writeJSON(_ object: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: configuration.evidenceRoot.appendingPathComponent(name), options: .atomic)
    }

}

@MainActor
private final class HUDStateCard: NSStackView {
    let state: HUDStatesGalleryFixture.State
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")

    init(state: HUDStatesGalleryFixture.State) {
        self.state = state
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.97).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        icon.image = NSImage(systemSymbolName: Self.symbolName(for: state.iconRole), accessibilityDescription: state.title)
        icon.contentTintColor = Self.color(for: state.tone)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let heading = NSStackView(views: [icon, title])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8

        title.stringValue = state.title
        title.textColor = .white
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        detail.stringValue = state.detail
        detail.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 245
        metadata.stringValue = state.id + "  |  " + state.actionability + "  |  " + state.dismissal
        metadata.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metadata.textColor = Self.color(for: state.tone)
        metadata.maximumNumberOfLines = 3
        metadata.lineBreakMode = .byWordWrapping
        metadata.preferredMaxLayoutWidth = 245

        addArrangedSubview(heading)
        addArrangedSubview(detail)
        addArrangedSubview(metadata)
        setAccessibilityRole(.group)
        setAccessibilityLabel(state.title + ". " + state.detail)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 285),
            heightAnchor.constraint(equalToConstant: 180)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func apply(textScale: CGFloat, reducedMotion: Bool) {
        title.font = .systemFont(ofSize: 14 * textScale, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 12 * textScale)
        detail.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        metadata.font = .monospacedSystemFont(ofSize: 10 * textScale, weight: .regular)
        layer?.borderColor = Self.color(for: state.tone).withAlphaComponent(reducedMotion ? 0.75 : 0.45).cgColor
    }

    private static func symbolName(for role: String) -> String {
        switch role {
        case "confirmation": "checkmark.circle.fill"
        case "attention": "exclamationmark.triangle.fill"
        case "failure": "xmark.octagon.fill"
        case "recording": "record.circle.fill"
        case "destination": "cursorarrow.rays"
        default: "info.circle.fill"
        }
    }

    private static func color(for tone: String) -> NSColor {
        switch tone {
        case "success": .systemGreen
        case "warning": .systemOrange
        case "critical", "recording": .systemRed
        case "informational": .controlAccentColor
        default: .secondaryLabelColor
        }
    }
}

@MainActor
private final class HUDGalleryPanelProbe {
    let panel: MacUIFloatingPanel
    let content: HUDGalleryPanelContent
    private var generation: UInt64 = 0
    private var timer: Timer?
    private var previewLastTime: TimeInterval?
    private(set) var previewAcceptedUpdates = 0
    private(set) var staleGenerationRejected = false
    private(set) var destinationStatePersists = false
    private(set) var previewStoppedOnReplacement = false

    init(configuration: GalleryConfiguration, state: HUDStatesGalleryFixture.State) {
        panel = MacUIFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 336, height: 96))
        panel.appearance = NSAppearance(named: .darkAqua)
        content = HUDGalleryPanelContent(state: state)
        panel.contentView = content
        panel.setContentSize(NSSize(width: 336, height: 96))
        content.setFrameSize(NSSize(width: 336, height: 96))
        content.autoresizingMask = [.width, .height]
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Synthetic Oigo HUD")
        panel.setFrameOrigin(NSPoint(x: 420, y: 520))
        _ = present(state: state, generation: 10)
        let acceptedOld = present(state: state, generation: 9)
        staleGenerationRejected = !acceptedOld
        _ = present(state: state, generation: 10)
        let samples: [(TimeInterval, Bool)] = [
            (0.0, true),
            (0.1, false),
            (0.2, true),
            (0.4, true),
            (0.61, true)
        ]
        for (time, expected) in samples {
            let accepted = updatePreview(at: time)
            if accepted == expected, accepted { previewAcceptedUpdates += 1 }
        }
        let previewWasVisible = !content.previewText.isEmpty
        _ = present(state: state, generation: 11)
        previewStoppedOnReplacement = previewWasVisible && content.previewText.isEmpty
        _ = present(state: state, generation: 12)
        panel.orderFront(nil)
        _ = configuration
    }

    var timerActive: Bool { timer != nil }

    func present(state: HUDStatesGalleryFixture.State, generation: UInt64) -> Bool {
        guard generation >= self.generation else { return false }
        self.generation = generation
        timer?.invalidate()
        timer = nil
        previewLastTime = nil
        let hadPreview = !content.previewText.isEmpty
        content.apply(state: state)
        if hadPreview {
            content.previewText = ""
        }
        if state.recordingTimer {
            timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.content.elapsed = "00:12"
                }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
        if state.id == "paste-again-destination" {
            destinationStatePersists = true
        }
        content.setFrameSize(NSSize(width: 336, height: 96))
        panel.orderFront(nil)
        return true
    }

    func updatePreview(at time: TimeInterval) -> Bool {
        guard content.state.preview,
              panel.isVisible else { return false }
        guard let previewLastTime else {
            self.previewLastTime = time
            content.previewText = "synthetic preview"
            return true
        }
        guard time - previewLastTime >= 0.2 else { return false }
        self.previewLastTime = time
        content.previewText = "synthetic preview"
        return true
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        previewLastTime = nil
        content.previewText = ""
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

@MainActor
private final class HUDGalleryPanelContent: NSStackView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private(set) var state: HUDStatesGalleryFixture.State
    var elapsed: String = "" {
        didSet { elapsedLabel.stringValue = elapsed }
    }
    var previewText: String = "" {
        didSet {
            previewLabel.stringValue = previewText.isEmpty ? "" : "\u{201C}" + previewText + "\u{201D}"
            previewLabel.isHidden = previewText.isEmpty
        }
    }

    init(state: HUDStatesGalleryFixture.State) {
        self.state = state
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.97).cgColor

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 304
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        elapsedLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.preferredMaxLayoutWidth = 304
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSStackView(views: [icon, title, elapsedLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(heading)
        addArrangedSubview(detail)
        addArrangedSubview(previewLabel)
        previewLabel.isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Synthetic Oigo HUD")
        apply(state: state)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 336),
            heightAnchor.constraint(equalToConstant: 96),
            detail.widthAnchor.constraint(equalToConstant: 304),
            previewLabel.widthAnchor.constraint(equalToConstant: 304)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func apply(state: HUDStatesGalleryFixture.State) {
        self.state = state
        title.stringValue = state.title
        detail.stringValue = state.detail
        elapsed = state.recordingTimer ? "00:12" : ""
        elapsedLabel.isHidden = !state.recordingTimer
        previewText = state.preview ? "synthetic preview" : ""
        icon.image = NSImage(
            systemSymbolName: symbolName(for: state.iconRole),
            accessibilityDescription: state.title
        )
        icon.contentTintColor = color(for: state.tone)
        setAccessibilityLabel(state.title + ". " + state.detail)
    }

    private func symbolName(for role: String) -> String {
        switch role {
        case "confirmation": "checkmark.circle.fill"
        case "attention": "exclamationmark.triangle.fill"
        case "failure": "xmark.octagon.fill"
        case "recording": "record.circle.fill"
        case "destination": "cursorarrow.rays"
        default: "info.circle.fill"
        }
    }

    private func color(for tone: String) -> NSColor {
        switch tone {
        case "success": .systemGreen
        case "warning": .systemOrange
        case "critical", "recording": .systemRed
        case "informational": .controlAccentColor
        default: .secondaryLabelColor
        }
    }
}
