import AppKit
import OigoCore
import OigoPresentation

private final class OigoHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OigoStatusSurfaceCommand {
    case history
    case settings
    case quit
    case popover(OigoPopoverCommand)
}

@MainActor
final class StatusSurfaceController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let panel: OigoHUDPanel
    private let label: NSTextField
    private let detailLabel: NSTextField
    private let popover = NSPopover()
    private lazy var popoverController = OigoPopoverViewController { [weak self] command in
        self?.handlePopoverCommand(command)
    }
    private let utilityMenu = NSMenu()
    private let commandHandler: (OigoStatusSurfaceCommand) -> Void
    private weak var statusItem: NSStatusItem?
    private var dismissalTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var keyboardMonitor: Any?
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

        popover.contentViewController = popoverController
        popover.contentSize = NSSize(width: 340, height: 360)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

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
        statusItem?.button?.toolTip = state.status.rawValue
    }

    func publish(
        _ state: OigoPresentationState,
        inputs: OigoPresentationInputs,
        inputOptions: [OigoPopoverInputOption],
        generation: UInt64
    ) {
        guard generation > presentationGeneration else {
            return
        }
        presentationGeneration = generation
        let presentation = OigoPopoverPresentation.compose(state: state, inputs: inputs)
        popoverController.render(
            presentation,
            generation: generation,
            inputOptions: inputOptions
        )
        popover.contentSize = popoverController.preferredContentSize
    }

    func teardown() {
        utilityMenu.cancelTracking()
        popover.close()
        for item in utilityMenu.items {
            item.target = nil
        }
        popoverController.dismiss()
        removeKeyboardMonitor()
        teardownStatusItemHandler()
        hide()
        utilityMenu.delegate = nil
        popover.delegate = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        _ = menu
    }

    func popoverDidShow(_ notification: Notification) {
        _ = notification
        installKeyboardMonitor()
        popoverController.beginPresentation()
    }

    func popoverDidClose(_ notification: Notification) {
        _ = notification
        removeKeyboardMonitor()
        popoverController.dismiss()
    }

    func showControlFailure(_ message: String) {
        popoverController.showControlFailure(message)
        popover.contentSize = popoverController.preferredContentSize
    }

    func clearControlFailure() {
        popoverController.clearControlFailure()
        popover.contentSize = popoverController.preferredContentSize
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

    private func handlePopoverCommand(_ command: OigoPopoverCommand) {
        guard command.generation == presentationGeneration else {
            return
        }
        switch command.intent {
        case .dismiss:
            popover.close()
        case .moveFocus(let direction):
            popoverController.moveFocus(direction)
        case .invokeFocused:
            popoverController.invokeFocusedControl()
        case .presentation(let action):
            if [.pasteAgain, .openHistory, .openSettings, .quit].contains(action) {
                popover.close()
            }
            commandHandler(.popover(command))
        case .selectInput:
            commandHandler(.popover(command))
        }
    }

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === popoverController.view.window else {
                return event
            }
            let intent: OigoPopoverCommandIntent? = switch event.keyCode {
            case 53: .dismiss
            case 48: .moveFocus(event.modifierFlags.contains(.shift) ? .previous : .next)
            case 36: .invokeFocused(.returnKey)
            case 49: .invokeFocused(.space)
            default: nil
            }
            guard let intent else {
                return event
            }
            handlePopoverCommand(OigoPopoverCommand(
                generation: presentationGeneration,
                intent: intent
            ))
            return nil
        }
    }

    private func removeKeyboardMonitor() {
        guard let keyboardMonitor else {
            return
        }
        NSEvent.removeMonitor(keyboardMonitor)
        self.keyboardMonitor = nil
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
