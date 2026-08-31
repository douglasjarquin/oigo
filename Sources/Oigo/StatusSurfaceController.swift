import AppKit
import OigoCore
import OigoPresentation

enum OigoStatusSurfaceCommand {
    case history
    case settings
    case quit
    case popover(OigoPopoverCommand)
}

@MainActor
final class StatusSurfaceController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let hudController = OigoHUDController()
    private let popover = NSPopover()
    private lazy var popoverController = OigoPopoverViewController { [weak self] command in
        self?.handlePopoverCommand(command)
    }
    private let utilityMenu = NSMenu()
    private let commandHandler: (OigoStatusSurfaceCommand) -> Void
    private weak var statusItem: NSStatusItem?
    private var keyboardMonitor: Any?
    private var hudState: OigoHUDState?
    private var hudGeneration: UInt64?
    private var presentationGeneration: UInt64 = 0

    init(commandHandler: @escaping (OigoStatusSurfaceCommand) -> Void) {
        self.commandHandler = commandHandler
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
        shutdownHUD()
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

    func presentHUD(
        _ state: OigoHUDState,
        generation: UInt64,
        geometry: HUDTargetGeometrySnapshot?,
        startedAt: Date? = nil,
        preview: String = "",
        shortcutCopy: OigoShortcutCopy
    ) {
        if hudGeneration != generation || hudState != state {
            let displays = AccessibilityHUDGeometryCapture.displayGeometry()
            let fallbackDisplayID = geometry?.targetDisplayID ?? displays.first?.id
            let placement = HUDPlacementInput(
                snapshot: geometry,
                currentGeneration: generation,
                displays: displays,
                frontmostDisplayID: fallbackDisplayID,
                mainDisplayID: fallbackDisplayID,
                panelSize: HUDSize(width: 336, height: 96)
            )
            guard hudController.present(
                state,
                generation: generation,
                placementInput: placement,
                startedAt: startedAt,
                shortcutReleaseHint: shortcutCopy.releaseHint
            ) else {
                return
            }
            hudState = state
            hudGeneration = generation
        }
        if !preview.isEmpty {
            _ = hudController.updatePreview(preview, generation: generation)
        }
    }

    func hideHUD(generation: UInt64) {
        guard hudController.hide(generation: generation) else { return }
        hudState = nil
        hudGeneration = nil
    }

    func shutdownHUD() {
        hudController.shutdown()
        hudState = nil
        hudGeneration = nil
    }

    var hudResourceSnapshot: OigoHUDResourceSnapshot {
        hudController.resourceSnapshot
    }
}
