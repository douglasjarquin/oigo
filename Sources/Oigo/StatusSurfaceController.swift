import AppKit
import OigoCore

private final class OigoHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OigoStatusSurfaceCommand {
    case history
    case settings
    case quit
}

@MainActor
final class StatusSurfaceController: NSObject, NSMenuDelegate {
    private let panel: OigoHUDPanel
    private let label: NSTextField
    private let detailLabel: NSTextField
    private let popover = NSPopover()
    private let popoverStatusLabel = NSTextField(labelWithString: "")
    private let utilityMenu = NSMenu()
    private let commandHandler: (OigoStatusSurfaceCommand) -> Void
    private weak var statusItem: NSStatusItem?
    private var dismissalTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var recordingPreview = ""
    private var resourceLedger = OigoHUDResourceLedger()
    private var displayGeneration = 0
    private var presentationGeneration: UInt64 = 0

    init(commandHandler: @escaping (OigoStatusSurfaceCommand) -> Void) {
        self.commandHandler = commandHandler
        label = NSTextField(labelWithString: "")
        detailLabel = NSTextField(labelWithString: "")
        panel = OigoHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        label.font = .boldSystemFont(ofSize: 14)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 2
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.layer?.cornerRadius = 10
        let stack = NSStackView(views: [label, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        contentView.addSubview(stack)

        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        panel.contentView = contentView
        panel.orderOut(nil)

        super.init()

        let popoverController = NSViewController()
        let popoverContent = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 96))
        popoverStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        popoverStatusLabel.textColor = .secondaryLabelColor
        popoverStatusLabel.setAccessibilityLabel("Oigo status")
        popoverStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        popoverContent.addSubview(popoverStatusLabel)
        NSLayoutConstraint.activate([
            popoverStatusLabel.leadingAnchor.constraint(equalTo: popoverContent.leadingAnchor, constant: 18),
            popoverStatusLabel.trailingAnchor.constraint(equalTo: popoverContent.trailingAnchor, constant: -18),
            popoverStatusLabel.centerYAnchor.constraint(equalTo: popoverContent.centerYAnchor)
        ])
        popoverController.view = popoverContent
        popover.contentViewController = popoverController
        popover.contentSize = NSSize(width: 340, height: 96)
        popover.behavior = .transient
        popover.animates = false

        utilityMenu.autoenablesItems = false
        utilityMenu.delegate = self
        utilityMenu.addItem(commandItem(title: "History", action: #selector(openHistory)))
        utilityMenu.addItem(commandItem(title: "Settings", action: #selector(openSettings)))
        utilityMenu.addItem(.separator())
        utilityMenu.addItem(commandItem(title: "Quit", action: #selector(quit)))
    }

    func install(statusItem: NSStatusItem) {
        teardownStatusItemHandler()
        self.statusItem = statusItem
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(handleStatusItemEvent)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func publish(_ state: OigoPresentationState, generation: UInt64) {
        guard generation > presentationGeneration else {
            return
        }
        presentationGeneration = generation
        popoverStatusLabel.stringValue = state.status.rawValue
        popoverStatusLabel.setAccessibilityValue(state.status.rawValue)
    }

    func teardown() {
        utilityMenu.cancelTracking()
        popover.close()
        teardownStatusItemHandler()
        hide()
        utilityMenu.delegate = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        _ = menu
    }

    @objc private func handleStatusItemEvent() {
        guard let event = NSApp.currentEvent else {
            return
        }
        let isUtilityMenuEvent = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isUtilityMenuEvent {
            showUtilityMenu()
        } else if event.type == .leftMouseUp {
            togglePopover()
        }
    }

    private func togglePopover() {
        utilityMenu.cancelTracking()
        guard let button = statusItem?.button else {
            return
        }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showUtilityMenu() {
        popover.close()
        guard let button = statusItem?.button else {
            return
        }
        utilityMenu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4),
            in: button
        )
    }

    private func commandItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func teardownStatusItemHandler() {
        statusItem?.button?.target = nil
        statusItem?.button?.action = nil
        statusItem = nil
    }

    @objc private func openHistory() {
        commandHandler(.history)
    }

    @objc private func openSettings() {
        commandHandler(.settings)
    }

    @objc private func quit() {
        commandHandler(.quit)
    }

    func hide() {
        displayGeneration &+= 1
        dismissalTask?.cancel()
        dismissalTask = nil
        stopRecordingTimer()
        resourceLedger.close()
        recordingStartedAt = nil
        recordingPreview = ""
        panel.orderOut(nil)
    }

    func showRecording(
        startedAt: Date,
        preview: String,
        detail: String? = nil,
        anchoredTo button: NSStatusBarButton?
    ) {
        displayGeneration &+= 1
        dismissalTask?.cancel()
        dismissalTask = nil
        if recordingStartedAt == nil {
            recordingStartedAt = startedAt
            recordingPreview = preview
            resourceLedger.beginRecording()
            recordingTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshRecordingLabel()
                }
            }
            if let recordingTimer {
                RunLoop.main.add(recordingTimer, forMode: .common)
            }
        }
        recordingPreview = detail ?? preview
        refreshRecordingLabel()
        position(anchoredTo: button)
        panel.orderFront(nil)
    }

    func showProcessing(
        _ state: OigoHUDProcessingState,
        detail: String,
        anchoredTo button: NSStatusBarButton?
    ) {
        displayGeneration &+= 1
        let generation = displayGeneration
        dismissalTask?.cancel()
        dismissalTask = nil
        stopRecordingTimer()
        recordingStartedAt = nil
        label.stringValue = state.rawValue
        detailLabel.stringValue = detail
        position(anchoredTo: button)
        panel.orderFront(nil)
        guard [.pasteAttempted, .pasted, .copied, .completedPasteFailed, .failed].contains(state) else {
            return
        }
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_800_000_000)
            } catch {
                return
            }
            guard let self, self.displayGeneration == generation else {
                return
            }
            self.hide()
        }
    }

    private func refreshRecordingLabel() {
        guard let recordingStartedAt else {
            return
        }
        let elapsed = max(0, Date().timeIntervalSince(recordingStartedAt))
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        label.stringValue = "● Recording  " + String(format: "%02d:%02d", minutes, seconds)
        detailLabel.stringValue = OigoHUDPreviewPolicy.bounded(recordingPreview)
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingPreview = ""
        resourceLedger.endRecording()
    }

    private func position(anchoredTo button: NSStatusBarButton?) {
        if let button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            var origin = NSPoint(
                x: buttonFrame.midX - (panel.frame.width / 2),
                y: buttonFrame.minY - panel.frame.height - 8
            )
            if let screen = window.screen ?? NSScreen.main {
                let visibleFrame = screen.visibleFrame
                origin.x = min(
                    max(origin.x, visibleFrame.minX + 8),
                    visibleFrame.maxX - panel.frame.width - 8
                )
                origin.y = min(
                    max(origin.y, visibleFrame.minY + 8),
                    visibleFrame.maxY - panel.frame.height - 8
                )
            }
            panel.setFrameOrigin(origin)
        }
    }
}
