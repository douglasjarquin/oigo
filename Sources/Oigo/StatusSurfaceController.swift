import AppKit
import OigoCore

private final class OigoHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusSurfaceController {
    private let panel: OigoHUDPanel
    private let label: NSTextField
    private let detailLabel: NSTextField
    private var dismissalTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var recordingPreview = ""
    private var resourceLedger = OigoHUDResourceLedger()
    private var displayGeneration = 0

    init() {
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
