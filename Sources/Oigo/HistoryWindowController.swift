import AppKit
import OigoCore

@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let loadTranscript: (SessionHistoryEntry, SessionTextSource) -> Result<String, Error>
    private let copyRawTranscript: (SessionHistoryEntry) -> Void
    private let copyCleanTranscript: (SessionHistoryEntry) -> Void
    private let pasteAgain: (SessionHistoryEntry) -> Void
    private let pasteCleanAgain: (SessionHistoryEntry) -> Void
    private let cleanAgain: (SessionHistoryEntry) -> Void
    private let playRecording: (SessionHistoryEntry) -> Void
    private let retryTranscription: (SessionHistoryEntry) -> Void
    private let revealRecording: (SessionHistoryEntry) -> Void
    private let deleteSession: (SessionHistoryEntry) -> Void
    private let runIdleMaintenance: () -> Void

    private var entries: [SessionHistoryEntry] = []
    private var isReloading = false
    private var preservedSelectionID: UUID?
    private var commandAvailability: AppCommandAvailability?
    private let tableView = NSTableView()
    private let detailTitle = NSTextField(labelWithString: "No session selected")
    private let detailStatus = NSTextField(labelWithString: "")
    private let transcriptView = NSTextView()
    private let failureLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let transcriptVersionPopup = NSPopUpButton()
    private let copyButton = NSButton(title: "Copy Raw Transcript", target: nil, action: nil)
    private let copyCleanButton = NSButton(title: "Copy Clean Transcript", target: nil, action: nil)
    private let pasteAgainButton = NSButton(title: "Paste Again", target: nil, action: nil)
    private let pasteCleanAgainButton = NSButton(title: "Paste Clean Again", target: nil, action: nil)
    private let cleanAgainButton = NSButton(title: "Clean Again", target: nil, action: nil)
    private let playButton = NSButton(title: "Play Recording", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry Transcription", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal Recording", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Session", target: nil, action: nil)

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    init(
        loadTranscript: @escaping (SessionHistoryEntry, SessionTextSource) -> Result<String, Error>,
        copyRawTranscript: @escaping (SessionHistoryEntry) -> Void,
        copyCleanTranscript: @escaping (SessionHistoryEntry) -> Void,
        pasteAgain: @escaping (SessionHistoryEntry) -> Void,
        pasteCleanAgain: @escaping (SessionHistoryEntry) -> Void,
        cleanAgain: @escaping (SessionHistoryEntry) -> Void,
        playRecording: @escaping (SessionHistoryEntry) -> Void,
        retryTranscription: @escaping (SessionHistoryEntry) -> Void,
        revealRecording: @escaping (SessionHistoryEntry) -> Void,
        deleteSession: @escaping (SessionHistoryEntry) -> Void,
        runIdleMaintenance: @escaping () -> Void
    ) {
        self.loadTranscript = loadTranscript
        self.copyRawTranscript = copyRawTranscript
        self.copyCleanTranscript = copyCleanTranscript
        self.pasteAgain = pasteAgain
        self.pasteCleanAgain = pasteCleanAgain
        self.cleanAgain = cleanAgain
        self.playRecording = playRecording
        self.retryTranscription = retryTranscription
        self.revealRecording = revealRecording
        self.deleteSession = deleteSession
        self.runIdleMaintenance = runIdleMaintenance

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo History"
        window.minSize = NSSize(width: 900, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(entries: [SessionHistoryEntry]) {
        let selectedID = selectedEntry?.id
        let selectedSource = selectedTranscriptSource
        isReloading = true
        defer { isReloading = false }
        self.entries = entries
        tableView.reloadData()
        if let selectedID,
           let row = entries.firstIndex(where: { $0.id == selectedID }) {
            preservedSelectionID = selectedID
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedTranscriptSource = selectedSource
            transcriptVersionPopup.selectItem(at: selectedSource == .processed ? 1 : 0)
            updateDetail(for: selectedEntry)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedEntry?.id == selectedID else {
                    return
                }
                self.selectedTranscriptSource = selectedSource
                self.transcriptVersionPopup.selectItem(at: selectedSource == .processed ? 1 : 0)
                self.updateDetail(for: self.selectedEntry)
                self.preservedSelectionID = nil
            }
        } else if !entries.isEmpty {
            preservedSelectionID = nil
            selectedTranscriptSource = .raw
            transcriptVersionPopup.selectItem(at: 0)
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            preservedSelectionID = nil
            updateDetail(for: nil)
        }
    }

    func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
    }

    func setCleanAgainEnabled(_ enabled: Bool) {
        cleanAgainButton.isEnabled = enabled
            && selectedEntry != nil
            && commandAvailability?.canCleanAgain ?? true
    }

    func setCommandAvailability(_ availability: AppCommandAvailability) {
        commandAvailability = availability
        setActionButtons(enabled: selectedEntry != nil, entry: selectedEntry)
    }

    func showCleanTranscript() {
        guard selectedEntry != nil else {
            return
        }
        selectedTranscriptSource = .processed
        transcriptVersionPopup.selectItem(at: 1)
        updateDetail(for: selectedEntry)
    }

    func showAndFocus() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        _ = tableView
        return entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        _ = tableView
        guard let tableColumn, entries.indices.contains(row) else {
            return nil
        }
        let entry = entries[row]
        let identifier = tableColumn.identifier.rawValue
        let text: String
        switch identifier {
        case "date":
            text = listDateFormatter.string(from: entry.session.metadata.createdAt)
        case "duration":
            text = Self.durationText(entry.session.metadata.duration)
        case "transcript":
            text = entry.firstTranscriptLine ?? "No transcript"
        case "source":
            text = switch entry.session.metadata.insertionTextSource {
            case .raw:
                "Raw"
            case .clean:
                "Clean"
            case nil:
                entry.textSource == .processed ? "Clean available" : "Raw"
            }
        case "status":
            text = Self.statusText(entry.session.metadata.state)
                + " · "
                + entry.session.metadata.configurationIdentity.historyLabel
        case "paste":
            text = Self.pasteText(entry.session.metadata.insertionOutcome)
        default:
            text = ""
        }

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        guard !isReloading else {
            return
        }
        if let preservedSelectionID {
            guard let currentID = selectedEntry?.id else {
                return
            }
            if currentID == preservedSelectionID {
                updateDetail(for: selectedEntry)
                return
            }
            self.preservedSelectionID = nil
        }
        selectedTranscriptSource = .raw
        transcriptVersionPopup.selectItem(at: 0)
        updateDetail(for: selectedEntry)
    }

    @objc private func copyRawTranscriptAction() {
        guard let selectedEntry else { return }
        copyRawTranscript(selectedEntry)
    }

    @objc private func copyCleanTranscriptAction() {
        guard let selectedEntry else { return }
        copyCleanTranscript(selectedEntry)
    }

    @objc private func pasteAgainAction() {
        guard let selectedEntry else { return }
        pasteAgain(selectedEntry)
    }

    @objc private func pasteCleanAgainAction() {
        guard let selectedEntry else { return }
        pasteCleanAgain(selectedEntry)
    }

    @objc private func cleanAgainAction() {
        guard let selectedEntry else { return }
        cleanAgain(selectedEntry)
    }

    @objc private func transcriptVersionAction() {
        guard let selectedEntry else { return }
        selectedTranscriptSource = transcriptVersionPopup.indexOfSelectedItem == 1
            ? .processed
            : .raw
        updateDetail(for: selectedEntry)
    }

    @objc private func playRecordingAction() {
        guard let selectedEntry else { return }
        playRecording(selectedEntry)
    }

    @objc private func retryTranscriptionAction() {
        guard let selectedEntry else { return }
        retryTranscription(selectedEntry)
    }

    @objc private func revealRecordingAction() {
        guard let selectedEntry else { return }
        revealRecording(selectedEntry)
    }

    @objc private func deleteSessionAction() {
        guard let selectedEntry else { return }
        deleteSession(selectedEntry)
    }

    @objc private func runIdleMaintenanceAction() {
        runIdleMaintenance()
    }

    private var selectedEntry: SessionHistoryEntry? {
        let row = tableView.selectedRow
        guard entries.indices.contains(row) else {
            return nil
        }
        return entries[row]
    }

    private var selectedTranscriptSource: SessionTextSource = .raw

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let listTitle = NSTextField(labelWithString: "Sessions")
        listTitle.font = .boldSystemFont(ofSize: 15)
        let listScrollView = NSScrollView()
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.documentView = tableView

        configureTable()
        let listStack = NSStackView(views: [listTitle, listScrollView])
        listStack.orientation = .vertical
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 12)

        let detailView = makeDetailView()
        splitView.addArrangedSubview(listStack)
        splitView.addArrangedSubview(detailView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setPosition(760, ofDividerAt: 0)

        let maintenanceButton = NSButton(
            title: "Run Idle Maintenance",
            target: self,
            action: #selector(runIdleMaintenanceAction)
        )
        maintenanceButton.bezelStyle = .rounded
        let footer = NSStackView(views: [maintenanceButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 12, right: 20)

        let root = NSStackView(views: [splitView, footer])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            listStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 720)
        ])
        showMessage("")
    }

    private func configureTable() {
        tableView.addTableColumn(column(identifier: "date", title: "Date / Time", width: 145))
        tableView.addTableColumn(column(identifier: "duration", title: "Duration", width: 55))
        tableView.addTableColumn(column(identifier: "transcript", title: "Transcript", width: 130))
        tableView.addTableColumn(column(identifier: "source", title: "Inserted", width: 100))
        tableView.addTableColumn(column(identifier: "status", title: "Status", width: 170))
        tableView.addTableColumn(column(identifier: "paste", title: "Paste", width: 92))
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 38
        tableView.headerView = NSTableHeaderView()
        tableView.selectionHighlightStyle = .regular
    }

    private func makeDetailView() -> NSView {
        detailTitle.font = .boldSystemFont(ofSize: 18)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailStatus.textColor = .secondaryLabelColor
        failureLabel.textColor = .systemOrange
        failureLabel.lineBreakMode = .byWordWrapping
        failureLabel.maximumNumberOfLines = 3
        failureLabel.preferredMaxLayoutWidth = 440
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 14)
        transcriptView.textContainerInset = NSSize(width: 12, height: 12)
        transcriptView.backgroundColor = .textBackgroundColor
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.documentView = transcriptView

        configureButton(copyButton, action: #selector(copyRawTranscriptAction))
        configureButton(copyCleanButton, action: #selector(copyCleanTranscriptAction))
        configureButton(pasteAgainButton, action: #selector(pasteAgainAction))
        configureButton(pasteCleanAgainButton, action: #selector(pasteCleanAgainAction))
        configureButton(cleanAgainButton, action: #selector(cleanAgainAction))
        configureButton(playButton, action: #selector(playRecordingAction))
        configureButton(retryButton, action: #selector(retryTranscriptionAction))
        configureButton(revealButton, action: #selector(revealRecordingAction))
        configureButton(deleteButton, action: #selector(deleteSessionAction))

        transcriptVersionPopup.addItems(withTitles: ["Raw transcript", "Clean transcript"])
        transcriptVersionPopup.target = self
        transcriptVersionPopup.action = #selector(transcriptVersionAction)
        transcriptVersionPopup.controlSize = .small
        transcriptVersionPopup.toolTip = "Choose which durable transcript version to display"

        let firstRow = NSStackView(views: [transcriptVersionPopup, copyButton, copyCleanButton])
        let secondRow = NSStackView(views: [cleanAgainButton, pasteAgainButton, pasteCleanAgainButton])
        let thirdRow = NSStackView(views: [playButton, retryButton, revealButton, deleteButton])
        for row in [firstRow, secondRow, thirdRow] {
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
        }

        let stack = NSStackView(
            views: [detailTitle, detailStatus, failureLabel, transcriptScroll, firstRow, secondRow, thirdRow, messageLabel]
        )
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 20)
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [firstRow, secondRow, thirdRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
            ).isActive = true
        }
        transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return stack
    }

    private func updateDetail(for entry: SessionHistoryEntry?) {
        guard let entry else {
            detailTitle.stringValue = "No session selected"
            detailStatus.stringValue = "Select a session to inspect its transcript and actions."
            failureLabel.stringValue = ""
            transcriptView.string = ""
            transcriptVersionPopup.selectItem(at: 0)
            setActionButtons(enabled: false, entry: nil)
            return
        }

        detailTitle.stringValue = dateFormatter.string(from: entry.session.metadata.createdAt)
        transcriptVersionPopup.selectItem(at: selectedTranscriptSource == .processed ? 1 : 0)
        detailStatus.stringValue = Self.statusText(entry.session.metadata.state)
            + " · " + (selectedTranscriptSource == .processed ? "Clean transcript" : "Raw transcript")
            + " · " + entry.session.metadata.configurationIdentity.historyLabel
        failureLabel.stringValue = [
            entry.session.metadata.failureReason,
            entry.session.metadata.insertionFailureReason,
            entry.session.metadata.cleanupFallbackReason
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
        switch loadTranscript(entry, selectedTranscriptSource) {
        case .success(let transcript):
            transcriptView.string = transcript
        case .failure:
            transcriptView.string = "Transcript unavailable."
            showMessage("Could not load the selected transcript.")
        }
        setActionButtons(enabled: true, entry: entry)
    }

    private func setActionButtons(enabled: Bool, entry: SessionHistoryEntry?) {
        let capabilities = entry.map { entry in
            DictationHistoryActions.capabilities(
                sessionState: entry.session.metadata.state,
                hasValidRaw: FileManager.default.fileExists(atPath: entry.session.rawTextURL.path),
                hasAudio: FileManager.default.fileExists(atPath: entry.session.audioURL.path)
            )
        }
        let canUseTranscript = enabled && capabilities?.copyAvailable == true
        let sessionCommandsEnabled = commandAvailability?.canPasteAgain ?? true
        copyButton.isEnabled = canUseTranscript
        pasteAgainButton.isEnabled = enabled
            && capabilities?.pasteAgainAvailable == true
            && sessionCommandsEnabled
        let canUseCleanTranscript = canUseTranscript && entry.map {
            FileManager.default.fileExists(atPath: $0.session.cleanTextURL.path)
        } == true
        transcriptVersionPopup.isEnabled = enabled && entry != nil
        copyCleanButton.isEnabled = canUseCleanTranscript
        pasteCleanAgainButton.isEnabled = canUseCleanTranscript && sessionCommandsEnabled
        cleanAgainButton.isEnabled = canUseTranscript && (commandAvailability?.canCleanAgain ?? true)
        playButton.isEnabled = enabled && entry.map { FileManager.default.fileExists(atPath: $0.session.audioURL.path) } == true
        retryButton.isEnabled = enabled
            && capabilities?.savedAudioRetryAvailable == true
            && (commandAvailability?.canRetry ?? true)
        revealButton.isEnabled = enabled && entry != nil
        deleteButton.isEnabled = enabled && entry.map { !$0.session.metadata.state.isUnfinished } == true
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
    }

    private func column(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = width
        return column
    }

    private static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "-"
        }
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func statusText(_ state: DictationSessionState) -> String {
        switch state {
        case .preparing, .recording, .stopping:
            "Active"
        case .retrying:
            "Retrying"
        case .completed:
            "Complete"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        case .interrupted:
            "Interrupted"
        }
    }

    private static func pasteText(_ outcome: InsertionOutcome?) -> String {
        guard let outcome else {
            return "None"
        }
        return switch outcome {
        case .pasted:
            "Pasted"
        case .dispatched:
            "Paste attempted"
        case .copied:
            "Copied"
        case .secureRejected:
            "Secure field"
        case .failed:
            "Paste failed"
        }
    }
}
