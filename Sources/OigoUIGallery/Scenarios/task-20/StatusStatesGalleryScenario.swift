import AppKit
import Foundation
import MacUtilityUI
import OigoIdentity
import OigoPresentation

@MainActor
final class StatusStatesGalleryScenario: GalleryScenario {
    override class var scenarioName: String { "status-states" }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        do {
            let fixture = try StatusStatesGalleryFixture.load(from: configuration.fixtureRoot)
            let asset = try StatusStatesGalleryFixture.loadAsset()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Oigo Status Identity - Synthetic Gallery"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 640)
            window.center()
            window.contentViewController = StatusStatesGalleryViewController(
                configuration: configuration,
                fixture: fixture,
                asset: asset
            )
            return window
        } catch let error as GalleryInputError {
            reject(error.category)
        } catch {
            reject("malformed-status-states-fixture")
        }
    }

    private static func reject(_ category: String) -> Never {
        FileHandle.standardError.write(Data(("ERROR rejected-input:" + category + "\n").utf8))
        exit(64)
    }
}

@MainActor
private struct StatusStatesGalleryFixture: Decodable {
    struct State: Decodable {
        let id: String
        let row: String
        let mark: String
        let status: String
        let title: String
        let detail: String
        let symbol: String
        let terminal: Bool
    }

    let scenario: String
    let fixture: String
    let states: [State]

    static func load(from root: URL) throws -> Self {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Self.self, from: data),
              fixture.scenario == "status-states",
              fixture.fixture == "all-variants",
              Set(fixture.states.map(\.id)).count == fixture.states.count else {
            throw GalleryInputError(category: "malformed-status-states-fixture")
        }
        for state in fixture.states {
            guard OigoPresentationStateRow(rawValue: state.row) != nil,
                  OigoMenuMark(rawValue: state.mark) != nil,
                  OigoPresentationStatus(rawValue: state.status) != nil else {
                throw GalleryInputError(category: "invalid-presentation-state")
            }
            guard !state.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GalleryInputError(category: "missing-symbol")
            }
            guard !state.title.isEmpty, !state.detail.isEmpty else {
                throw GalleryInputError(category: "malformed-status-states-fixture")
            }
        }
        guard fixture.states.count == 8 else {
            throw GalleryInputError(category: "malformed-status-states-fixture")
        }
        return fixture
    }

    static func loadAsset() throws -> NSImage {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Oigo/Assets.xcassets/OigoMenuBar.imageset", isDirectory: true)
        let image = NSImage(size: NSSize(width: 16, height: 22))
        for name in ["oigo-menubar.png", "oigo-menubar@2x.png"] {
            let url = root.appendingPathComponent(name)
            guard let representation = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else {
                throw GalleryInputError(category: "missing-authoritative-identity-asset")
            }
            representation.size = NSSize(width: 16, height: 22)
            image.addRepresentation(representation)
        }
        return image
    }
}

@MainActor
private final class StatusStatesGalleryViewController: NSViewController {
    private let configuration: GalleryConfiguration
    private let fixture: StatusStatesGalleryFixture
    private let asset: NSImage
    private let document = NSView()
    private let body = NSStackView()
    private var renderers: [OigoStatusIdentityRenderer] = []
    private var cards: [NSView] = []
    private var captured = false

    init(configuration: GalleryConfiguration, fixture: StatusStatesGalleryFixture, asset: NSImage) {
        self.configuration = configuration
        self.fixture = fixture
        self.asset = asset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = MacUITokens.Colors.windowBackground.cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = MacUITokens.Spacing.section
        body.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.window,
            left: MacUITokens.Spacing.window,
            bottom: MacUITokens.Spacing.window,
            right: MacUITokens.Spacing.window
        )
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)

        let title = NSTextField(labelWithString: "Oigo status identity variants")
        title.font = MacUITokens.Typography.heading
        title.textColor = MacUITokens.Colors.primaryLabel
        addAccessibility(title, identifier: "oigo.status-gallery.title", label: title.stringValue, role: .staticText)
        body.addArrangedSubview(title)

        let detail = NSTextField(
            wrappingLabelWithString: "Synthetic artwork only. The same primary stroke is rendered for idle, processing, recording, attention, and inactive states."
        )
        detail.font = MacUITokens.Typography.callout
        detail.textColor = MacUITokens.Colors.secondaryLabel
        addAccessibility(detail, identifier: "oigo.status-gallery.detail", label: detail.stringValue, role: .staticText)
        body.addArrangedSubview(detail)

        let variants = NSStackView()
        variants.orientation = .vertical
        variants.alignment = .leading
        variants.spacing = MacUITokens.Spacing.controlGroup
        for state in fixture.states {
            let card = makeCard(for: state)
            cards.append(card)
            variants.addArrangedSubview(card)
        }
        body.addArrangedSubview(variants)

        let menuHeader = NSTextField(labelWithString: "Status menu and keyboard-owned commands")
        menuHeader.font = MacUITokens.Typography.section
        menuHeader.textColor = MacUITokens.Colors.primaryLabel
        addAccessibility(menuHeader, identifier: "oigo.status-gallery.menu-header", label: menuHeader.stringValue, role: .staticText)
        body.addArrangedSubview(menuHeader)
        body.addArrangedSubview(makeMenuPreview())

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
            body.widthAnchor.constraint(equalToConstant: 916)
        ])
        view = root
        addAccessibility(root, identifier: "oigo.status-gallery", label: "Oigo status identity gallery")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !captured else { return }
        captured = true
        view.layoutSubtreeIfNeeded()
        savePNG(of: document, named: "status-states.png")
        for (state, card) in zip(fixture.states, cards) {
            savePNG(of: card, named: "status-" + state.id + ".png")
        }
        writeReceipt()
    }

    private func makeCard(for fixtureState: StatusStatesGalleryFixture.State) -> NSView {
        guard let state = makePresentationState(for: fixtureState) else {
            fatalError("validated status state could not be constructed")
        }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        button.isBordered = false
        button.appearance = requestedAppearance()
        addAccessibility(
            button,
            identifier: "oigo.status.variant." + fixtureState.id,
            label: fixtureState.title,
            role: .button
        )
        let renderer = OigoStatusIdentityRenderer(sourceImageProvider: { [asset] in asset })
        renderer.render(state, on: button, isVisible: false)
        renderers.append(renderer)

        let image = NSImageView(image: button.image ?? NSImage(size: NSSize(width: 18, height: 18)))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: fixtureState.title)
        title.font = MacUITokens.Typography.section
        title.textColor = MacUITokens.Colors.primaryLabel
        let detail = NSTextField(wrappingLabelWithString: fixtureState.detail)
        detail.font = MacUITokens.Typography.callout
        detail.textColor = MacUITokens.Colors.secondaryLabel
        detail.maximumNumberOfLines = 2
        let metadata = NSTextField(labelWithString: fixtureState.id + " · " + fixtureState.symbol)
        metadata.font = MacUITokens.Typography.secondary
        metadata.textColor = MacUITokens.Colors.tertiaryLabel

        let text = NSStackView(views: [title, detail, metadata])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = MacUITokens.Spacing.tight
        let card = NSStackView(views: [image, text])
        card.orientation = .horizontal
        card.alignment = .centerY
        card.spacing = MacUITokens.Spacing.row
        card.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.row,
            left: MacUITokens.Spacing.row,
            bottom: MacUITokens.Spacing.row,
            right: MacUITokens.Spacing.row
        )
        card.wantsLayer = true
        card.layer?.cornerRadius = MacUITokens.Radius.contained
        card.layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
        card.widthAnchor.constraint(equalToConstant: 880).isActive = true
        addAccessibility(card, identifier: "oigo.status.card." + fixtureState.id, label: fixtureState.title)
        return card
    }

    private func makeMenuPreview() -> NSView {
        let menu = NSMenu(title: "Oigo status actions")
        let actions: [(OigoPresentationAction, String)] = [
            (.startDictation, "Start"),
            (.stopDictation, "Stop"),
            (.openHistory, "History"),
            (.openSettings, "Settings"),
            (.quit, "Quit")
        ]
        for (action, title) in actions {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.setAccessibilityIdentifier(OigoStatusMenuIdentity.identifier(for: action))
            item.setAccessibilityLabel(OigoStatusMenuIdentity.accessibilityName(for: action))
            menu.addItem(item)
        }
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = MacUITokens.Spacing.tight
        for item in menu.items {
            let label = NSTextField(labelWithString: item.accessibilityLabel() ?? item.title)
            label.font = MacUITokens.Typography.body
            label.textColor = MacUITokens.Colors.primaryLabel
            let identifier = NSTextField(labelWithString: item.accessibilityIdentifier())
            identifier.font = MacUITokens.Typography.secondary
            identifier.textColor = MacUITokens.Colors.secondaryLabel
            let row = NSStackView(views: [label, identifier])
            row.orientation = .horizontal
            row.spacing = MacUITokens.Spacing.row
            rows.addArrangedSubview(row)
        }
        rows.wantsLayer = true
        rows.layer?.cornerRadius = MacUITokens.Radius.contained
        rows.layer?.backgroundColor = MacUITokens.Colors.controlBackground.cgColor
        rows.edgeInsets = NSEdgeInsets(
            top: MacUITokens.Spacing.row,
            left: MacUITokens.Spacing.row,
            bottom: MacUITokens.Spacing.row,
            right: MacUITokens.Spacing.row
        )
        addAccessibility(rows, identifier: "oigo.status-menu", label: "Oigo status menu commands")
        return rows
    }

    private func makePresentationState(
        for fixtureState: StatusStatesGalleryFixture.State
    ) -> OigoPresentationState? {
        guard let row = OigoPresentationStateRow(rawValue: fixtureState.row),
              let mark = OigoMenuMark(rawValue: fixtureState.mark),
              let status = OigoPresentationStatus(rawValue: fixtureState.status) else {
            return nil
        }
        let terminal: OigoTerminalPresentationClass? = fixtureState.terminal ? .interruption : nil
        return OigoPresentationState(
            row: row,
            menuMark: mark,
            status: status,
            primaryAction: .enabled(.startDictation),
            context: terminal.map(OigoPresentationContext.terminal) ?? .readiness,
            notice: nil,
            latestSessionActions: .init(),
            hud: .hidden,
            availability: .init(
                initiatorsEnabled: mark != .hidden,
                commandsEnabled: true,
                windowsEnabled: true
            ),
            nextDictation: .none,
            copyOnly: .inactive,
            terminal: terminal
        )
    }

    private func requestedAppearance() -> NSAppearance? {
        if configuration.contrast == "increased" {
            return NSAppearance(named: .accessibilityHighContrastAqua)
        }
        switch configuration.appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    private func addAccessibility(
        _ view: NSView,
        identifier: String,
        label: String,
        role: NSAccessibility.Role = .group
    ) {
        view.setAccessibilityElement(true)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityRole(role)
        view.setAccessibilityLabel(label)
    }

    private func savePNG(of view: NSView, named name: String) {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0,
              view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let png = view.cacheAndCreatePNG(in: bitmap) else {
            return
        }
        try? png.write(to: configuration.evidenceRoot.appendingPathComponent(name), options: .atomic)
    }

    private func writeReceipt() {
        let variants = fixture.states.compactMap { fixtureState -> [String: String]? in
            guard let state = makePresentationState(for: fixtureState) else { return nil }
            let artwork = OigoStatusIdentityArtwork(state: state)
            return [
                "id": fixtureState.id,
                "variant": artwork.variant.rawValue,
                "shapeRole": artwork.shapeRole.rawValue,
                "colorRole": artwork.colorRole.rawValue,
                "accessibilityLabel": artwork.accessibilityLabel,
                "accessibilityValue": artwork.accessibilityValue
            ]
        }
        let actions = [OigoPresentationAction.startDictation, .stopDictation, .openHistory, .openSettings, .quit]
            .map { action in
                [
                    "identifier": OigoStatusMenuIdentity.identifier(for: action),
                    "accessibilityName": OigoStatusMenuIdentity.accessibilityName(for: action)
                ]
            }
        let receipt: [String: Any] = [
            "scenario": "status-states",
            "fixture": fixture.fixture,
            "stateCount": fixture.states.count,
            "variants": variants,
            "appearance": configuration.appearance,
            "contrast": configuration.contrast,
            "menuActions": actions,
            "synthetic": true,
            "thirdPartyData": "not-used"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: configuration.evidenceRoot.appendingPathComponent("status-states-receipt.json"), options: .atomic)
    }
}

private extension NSView {
    func cacheAndCreatePNG(in bitmap: NSBitmapImageRep) -> Data? {
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
