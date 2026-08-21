import AppKit
import Foundation

@MainActor
final class PopoverRoutingGalleryScenario: GalleryScenario {
    override class var scenarioName: String {
        "popover-routing"
    }

    override class func makeWindow(configuration: GalleryConfiguration) -> NSWindow {
        let surface = SyntheticStatusSurface(configuration: configuration)
        let window = PopoverRoutingHostWindow(surface: surface)
        surface.install()
        DispatchQueue.main.async {
            window.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
            surface.probeInactivePrimaryRoute()
            DispatchQueue.main.async {
                surface.activateForegroundSentinel { sentinelActivated in
                    DispatchQueue.main.async {
                        surface.recordDismissedActivation(sentinelActivated: sentinelActivated)
                        NSApp.setActivationPolicy(.regular)
                        window.orderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        surface.recordHostProbeActivation()
                    }
                }
            }
        }
        return window
    }
}

@MainActor
private final class PopoverRoutingHostWindow: NSPanel {
    private let surface: SyntheticStatusSurface

    init(surface: SyntheticStatusSurface) {
        self.surface = surface
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        title = "Oigo Task 11 Synthetic Route Fixture"
        center()

        let titleLabel = NSTextField(labelWithString: "Use the Oigo QA menu-bar item")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let detail = NSTextField(
            wrappingLabelWithString: "Left click toggles the popover. Right click opens History, Settings, a separator, and Quit."
        )
        detail.textColor = .secondaryLabelColor
        let primaryProbe = NSButton(
            title: "Primary Click Probe",
            target: surface,
            action: #selector(SyntheticStatusSurface.probePrimaryClick)
        )
        primaryProbe.setAccessibilityLabel("Primary Click Probe")
        let secondaryProbe = NSButton(
            title: "Secondary Click Utility Menu Probe",
            target: surface,
            action: #selector(SyntheticStatusSurface.probeSecondaryClick)
        )
        secondaryProbe.setAccessibilityLabel("Secondary Click Utility Menu Probe")
        let controlProbe = NSButton(
            title: "Control-click Utility Menu Probe",
            target: surface,
            action: #selector(SyntheticStatusSurface.probeControlClick)
        )
        controlProbe.setAccessibilityLabel("Control-click Utility Menu Probe")
        for probe in [primaryProbe, secondaryProbe, controlProbe] {
            probe.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        let probes = NSStackView(views: [primaryProbe, secondaryProbe, controlProbe])
        probes.orientation = .vertical
        probes.alignment = .leading
        probes.spacing = 8
        let stack = NSStackView(views: [titleLabel, detail, probes])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        let content = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        contentView = content
    }

    deinit {
        MainActor.assumeIsolated {
            surface.teardown()
        }
    }
}

@MainActor
private final class SyntheticStatusSurface: NSObject {
    private let configuration: GalleryConfiguration
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menu = NSMenu()
    private var routeGeneration: UInt64 = 0
    private var tornDown = false
    private var teardownTimer: Timer?
    private var observesApplicationResignation = false
    private var activationCompletion: ((Bool) -> Void)?

    init(configuration: GalleryConfiguration) {
        self.configuration = configuration
        super.init()

        let viewController = NSViewController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 164))
        let title = NSTextField(labelWithString: "Oigo")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let status = NSTextField(labelWithString: "Ready - Synthetic Task 11 route")
        status.textColor = .secondaryLabelColor
        let detail = NSTextField(
            wrappingLabelWithString: "Primary click toggles this transient popover. Secondary or Control-click opens the utility menu."
        )
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        let stack = NSStackView(views: [title, status, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        viewController.view = content
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 340, height: 164)
        popover.behavior = .transient
        popover.animates = false

        menu.autoenablesItems = false
        menu.addItem(commandItem(title: "History"))
        menu.addItem(commandItem(title: "Settings"))
        menu.addItem(.separator())
        menu.addItem(commandItem(title: "Quit"))
    }

    func install() {
        guard let button = statusItem.button else {
            return
        }
        button.title = "Oigo QA"
        button.toolTip = "Synthetic Task 11 status surface"
        button.setAccessibilityLabel("Oigo Task 11 Synthetic Status")
        button.target = self
        button.action = #selector(handleStatusItemEvent)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        record("installed surfaces=0 monitors=0 observers=0")
        print("ROUTING_READY status-item=synthetic surfaces=0 activation=host-managed")
        fflush(stdout)
        teardownTimer = Timer.scheduledTimer(withTimeInterval: 18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.teardown()
            }
        }
    }

    func teardown() {
        guard !tornDown else {
            return
        }
        tornDown = true
        teardownTimer?.invalidate()
        teardownTimer = nil
        finishForegroundSentinelActivation(activated: false)
        menu.cancelTracking()
        popover.close()
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        record("teardown surfaces=0 monitors=0 observers=0 handlers=0")
    }

    @objc private func handleStatusItemEvent() {
        guard let event = NSApp.currentEvent else {
            return
        }
        if event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            showMenu(route: event.type == .rightMouseUp ? "secondary" : "control-primary")
        } else if event.type == .leftMouseUp {
            togglePopover()
        }
    }

    @objc func probeControlClick(_ sender: NSButton) {
        showMenu(route: "control-primary", relativeTo: sender)
    }

    func probeInactivePrimaryRoute() {
        togglePopover()
        popover.close()
        NSApp.deactivate()
    }

    func activateForegroundSentinel(completion: @escaping (Bool) -> Void) {
        activationCompletion = completion
        if !NSApp.isActive {
            finishForegroundSentinelActivation(activated: true)
            return
        }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        observesApplicationResignation = true
        let requested = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .activate(options: [.activateAllWindows]) ?? false
        if !requested {
            finishForegroundSentinelActivation(activated: false)
        }
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        _ = notification
        finishForegroundSentinelActivation(activated: true)
    }

    private func finishForegroundSentinelActivation(activated: Bool) {
        if observesApplicationResignation {
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
            observesApplicationResignation = false
        }
        let completion = activationCompletion
        activationCompletion = nil
        completion?(activated)
    }

    func recordDismissedActivation(sentinelActivated: Bool) {
        routeGeneration &+= 1
        let passed = sentinelActivated && NSApp.activationPolicy() == .accessory && !NSApp.isActive
        record(
            "route=primary-dismissed generation=\(routeGeneration) popover=closed menu=closed assertion="
                + (passed ? "pass " : "fail ")
                + "sentinel-activated=" + (sentinelActivated ? "true " : "false ")
                + activationReceipt()
        )
    }

    func recordHostProbeActivation() {
        record("host-probe " + activationReceipt())
    }

    @objc func probePrimaryClick(_ sender: NSButton) {
        togglePopover(relativeTo: sender)
    }

    @objc func probeSecondaryClick(_ sender: NSButton) {
        showMenu(route: "secondary", relativeTo: sender)
    }

    private func togglePopover(relativeTo routeView: NSView? = nil) {
        menu.cancelTracking()
        guard let anchor = routeView ?? statusItem.button else {
            return
        }
        routeGeneration &+= 1
        if popover.isShown {
            popover.close()
            record("route=primary generation=\(routeGeneration) popover=closed menu=closed " + activationReceipt())
        } else {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            record("route=primary generation=\(routeGeneration) popover=open menu=closed " + activationReceipt())
        }
    }

    private func showMenu(route: String, relativeTo routeView: NSView? = nil) {
        popover.close()
        guard let anchor = routeView ?? statusItem.button else {
            return
        }
        routeGeneration &+= 1
        record("route=\(route) generation=\(routeGeneration) popover=closed menu=open " + activationReceipt())
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY - 4),
            in: anchor
        )
        record("route=\(route) generation=\(routeGeneration) popover=closed menu=closed " + activationReceipt())
    }

    private func commandItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(receiveCommand(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func receiveCommand(_ sender: NSMenuItem) {
        record("command=" + sender.title.lowercased() + " content=synthetic")
    }

    private func record(_ line: String) {
        let url = configuration.evidenceRoot.appendingPathComponent("gallery-route-events.log")
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func activationReceipt() -> String {
        let policy: String
        switch NSApp.activationPolicy() {
        case .accessory:
            policy = "accessory"
        case .prohibited:
            policy = "prohibited"
        case .regular:
            policy = "regular"
        @unknown default:
            policy = "unknown"
        }
        return "activation-policy=" + policy + " app-active=" + (NSApp.isActive ? "true" : "false")
    }
}
