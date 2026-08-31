import AppKit
import OigoCore

@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    private static let toolbarIdentifier = NSToolbar.Identifier("com.oigo.history.toolbar")
    private static let copyToolbarItem = NSToolbarItem.Identifier("com.oigo.history.copy")
    private static let pasteToolbarItem = NSToolbarItem.Identifier("com.oigo.history.paste-again")
    private static let playbackToolbarItem = NSToolbarItem.Identifier("com.oigo.history.playback")
    private static let moreToolbarItem = NSToolbarItem.Identifier("com.oigo.history.more")
    private let loadTranscript: (SessionHistoryEntry, SessionTextSource, @escaping @Sendable (Result<String, Error>) -> Void) -> Void
    private let copyRawTranscript: (SessionHistoryEntry) -> Void
    private let copyCleanTranscript: (SessionHistoryEntry) -> Void
    private let pasteAgain: (SessionHistoryEntry) -> Void
    private let pasteCleanAgain: (SessionHistoryEntry) -> Void
    private let cleanAgain: (SessionHistoryEntry) -> Void
    private let reapplyDictionary: (SessionHistoryEntry) -> Void
    private let playRecording: (SessionHistoryEntry) -> Void
    private let retryTranscription: (SessionHistoryEntry) -> Void
    private let revealRecording: (SessionHistoryEntry) -> Void
    private let deleteSession: (SessionHistoryEntry) -> Void
    private let runIdleMaintenance: () -> Void
    private let loadMore: () -> Void
    private let onClose: () -> Void

    private var entries: [SessionHistoryEntry] = []
    private var isReloading = false
    private var preservedSelectionID: UUID?
    private var commandAvailability: AppCommandAvailability?
    private var playingSessionID: UUID?
    private var hasMore = false
    private var isLoading = false
    private var transcriptLoadGeneration: UInt64 = 0
    private var cleanAgainOverride = true
    private var toolbarItemsByIdentifier: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private weak var mainRegionView: NSSplitView?
    private let moreMenu = NSMenu(title: "More")
    private let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    private let loadingLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let detailTitle = NSTextField(labelWithString: "No session selected")
    private let detailStatus = NSTextField(labelWithString: "")
    private let transcriptView = NSTextView()
    private let failureLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let transcriptVersionPopup = NSPopUpButton()

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
        loadTranscript: @escaping (SessionHistoryEntry, SessionTextSource, @escaping @Sendable (Result<String, Error>) -> Void) -> Void,
        copyRawTranscript: @escaping (SessionHistoryEntry) -> Void,
        copyCleanTranscript: @escaping (SessionHistoryEntry) -> Void,
        pasteAgain: @escaping (SessionHistoryEntry) -> Void,
        pasteCleanAgain: @escaping (SessionHistoryEntry) -> Void,
        cleanAgain: @escaping (SessionHistoryEntry) -> Void,
        reapplyDictionary: @escaping (SessionHistoryEntry) -> Void,
        playRecording: @escaping (SessionHistoryEntry) -> Void,
        retryTranscription: @escaping (SessionHistoryEntry) -> Void,
        revealRecording: @escaping (SessionHistoryEntry) -> Void,
        deleteSession: @escaping (SessionHistoryEntry) -> Void,
        runIdleMaintenance: @escaping () -> Void,
        loadMore: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.loadTranscript = loadTranscript
        self.copyRawTranscript = copyRawTranscript
        self.copyCleanTranscript = copyCleanTranscript
        self.pasteAgain = pasteAgain
        self.pasteCleanAgain = pasteCleanAgain
        self.cleanAgain = cleanAgain
        self.reapplyDictionary = reapplyDictionary
        self.playRecording = playRecording
        self.retryTranscription = retryTranscription
        self.revealRecording = revealRecording
        self.deleteSession = deleteSession
        self.runIdleMaintenance = runIdleMaintenance
        self.loadMore = loadMore
        self.onClose = onClose

        let window = OigoUtilityWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Oigo History"
        window.minSize = NSSize(width: 880, height: 520)
        window.identifier = NSUserInterfaceItemIdentifier("com.oigo.history.window")
        window.setFrameAutosaveName("Oigo.HistoryWindow")
        window.isRestorable = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in
            guard let self else { return }
            switch OigoUIIntegrationPolicy.resolveEscapeAction(from: [.closeUtilityWindow]) {
            default:
                self.window?.performClose(nil)
            }
        }
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: OigoHistoryWorkspacePolicy.defaultWidth, height: OigoHistoryWorkspacePolicy.defaultHeight))
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(
        entries: [SessionHistoryEntry],
        hasMore: Bool = false,
        isLoading: Bool = false
    ) {
        let selectedID = selectedEntry?.id
        let selectedSource = selectedTranscriptSource
        isReloading = true
        defer { isReloading = false }
        self.entries = entries
        self.hasMore = hasMore
        self.isLoading = isLoading
        updateLoadingChrome()
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
            updateDetail(for: selectedEntry)
        } else {
            preservedSelectionID = nil
            updateDetail(for: nil)
        }
    }

    func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        updateLoadingChrome()
    }

    func append(
        entries newEntries: [SessionHistoryEntry],
        hasMore: Bool,
        isLoading: Bool
    ) {
        let selectedID = selectedEntry?.id
        let selectedSource = selectedTranscriptSource
        isReloading = true
        defer { isReloading = false }
        let existingIDs = Set(entries.map(\.id))
        entries.append(contentsOf: newEntries.filter { !existingIDs.contains($0.id) })
        self.hasMore = hasMore
        self.isLoading = isLoading
        updateLoadingChrome()
        tableView.reloadData()
        if let selectedID,
           let row = entries.firstIndex(where: { $0.id == selectedID }) {
            preservedSelectionID = selectedID
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedTranscriptSource = selectedSource
        }
    }

    func setCleanAgainEnabled(_ enabled: Bool) {
        cleanAgainOverride = enabled
        updateToolbarState(for: selectedEntry)
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
        transcriptVersionPopup.selectItem(at: 2)
        updateDetail(for: selectedEntry)
    }

    func showAndFocus() {
        showWindow(nil)
        clampWindowToVisibleFrame()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidMove(_ notification: Notification) {
        _ = notification
        clampWindowToVisibleFrame()
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        clampWindowToVisibleFrame()
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        transcriptLoadGeneration &+= 1
        transcriptView.string = ""
        onClose()
    }

    func setPlaybackState(playingSessionID: UUID?, isPlaying: Bool) {
        self.playingSessionID = isPlaying ? playingSessionID : nil
        setActionButtons(enabled: selectedEntry != nil, entry: selectedEntry)
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
        _ = tableColumn
        guard entries.indices.contains(row) else {
            return nil
        }
        let projection = OigoHistoryRowProjection(entry: entries[row])
        let label = NSTextField(
            wrappingLabelWithString: listDateFormatter.string(from: projection.date)
                + "  ·  " + (projection.duration.map(Self.durationText) ?? "")
                + "\n" + projection.statusLabel
                + "\n" + projection.summary
        )
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3
        label.setAccessibilityLabel(projection.accessibilityLabel)
        label.setAccessibilityIdentifier("oigo.history.row.\(entries[row].id.uuidString)")
        return label
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
        if selectedTranscriptSource == .processed {
            pasteCleanAgain(selectedEntry)
        } else {
            pasteAgain(selectedEntry)
        }
    }

    @objc private func pasteCleanAgainAction() {
        guard let selectedEntry else { return }
        pasteCleanAgain(selectedEntry)
    }

    @objc private func cleanAgainAction() {
        guard let selectedEntry else { return }
        cleanAgain(selectedEntry)
    }

    @objc private func reapplyDictionaryAction() {
        guard let selectedEntry else { return }
        reapplyDictionary(selectedEntry)
    }

    @objc private func transcriptVersionAction() {
        guard let selectedEntry else { return }
        switch transcriptVersionPopup.indexOfSelectedItem {
        case 1:
            selectedTranscriptSource = .normalized
        case 2:
            selectedTranscriptSource = .processed
        default:
            selectedTranscriptSource = .raw
        }
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

    func task29TableViewForTesting() -> NSTableView { tableView }
    func task29MoreMenuTitlesForTesting() -> [String] {
        moreMenu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }
    func task29MoreMenuItemForTesting(title: String) -> NSMenuItem? {
        moreMenu.item(withTitle: title)
    }
    func task29MoreMenuSnapshotForTesting() -> [(identifier: String, title: String, isEnabled: Bool)] {
        moreMenu.items.filter { !$0.isSeparatorItem }.map {
            (identifier: $0.identifier?.rawValue ?? "", title: $0.title, isEnabled: $0.isEnabled)
        }
    }
    func task29MeasuredGeometryForTesting() -> (toolbarHeight: CGFloat, mainRegionHeight: CGFloat) {
        guard window?.toolbar != nil,
              let toolbarView = task29ToolbarView(),
              let platterView = task29ToolbarPlatter(in: toolbarView),
              let mainRegionView else {
            return (0, 0)
        }
        return (toolbarView.bounds.height - platterView.frame.minY, mainRegionView.frame.height)
    }
    private func task29ToolbarView() -> NSView? {
        guard let root = window?.contentView?.superview else { return nil }
        return task29View(named: "NSToolbarView", in: root)
    }
    private func task29ToolbarPlatter(in view: NSView) -> NSView? {
        task29View(named: "NSToolbarPlatterView", in: view)
    }
    private func task29View(named name: String, in view: NSView) -> NSView? {
        guard NSStringFromClass(type(of: view)) == name else {
            for child in view.subviews {
                if let result = task29View(named: name, in: child) { return result }
            }
            return nil
        }
        return view
    }
    func task29DetailSnapshotForTesting() -> (title: String, status: String, transcript: String, selectorEnabled: [Bool]) {
        (
            detailTitle.stringValue,
            detailStatus.stringValue,
            transcriptView.string,
            (0..<transcriptVersionPopup.numberOfItems).map { transcriptVersionPopup.item(at: $0)?.isEnabled ?? false }
        )
    }
    func task29SelectSourceForTesting(_ source: SessionTextSource) {
        selectedTranscriptSource = source
        transcriptVersionPopup.selectItem(at: source == .raw ? 0 : source == .normalized ? 1 : 2)
        updateDetail(for: selectedEntry)
    }
    func task29LoadingLabelForTesting() -> String { loadingLabel.stringValue }
    func task29LoadMoreButtonForTesting() -> NSButton { loadMoreButton }
    func task30InvokePasteAgainForTesting() { pasteAgainAction() }

    private func configureWindow() {
        guard let contentView = window?.contentView else {
            return
        }
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "Oigo.HistorySplit"

        let listScrollView = NSScrollView()
        listScrollView.hasVerticalScroller = true
        listScrollView.hasHorizontalScroller = false
        listScrollView.autohidesScrollers = true
        tableView.frame = NSRect(x: 0, y: 0, width: 324, height: 400)
        tableView.autoresizingMask = [.width]
        listScrollView.documentView = tableView

        configureTable()
        let listStack = NSStackView(views: [listScrollView])
        listStack.orientation = .vertical
        listStack.spacing = 0
        listStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        listStack.setAccessibilityElement(true)
        listStack.setAccessibilityIdentifier("oigo.history.list")
        listStack.setAccessibilityLabel("History sessions")

        let detailView = makeDetailView()
        detailView.setAccessibilityElement(true)
        detailView.setAccessibilityIdentifier("oigo.history.detail")
        detailView.setAccessibilityLabel("Selected history session")
        splitView.addArrangedSubview(listStack)
        splitView.addArrangedSubview(detailView)
        mainRegionView = splitView
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setAccessibilityElement(true)
        splitView.setAccessibilityIdentifier("oigo.history.split")
        splitView.setAccessibilityLabel("History list and detail")
        splitView.setPosition(340, ofDividerAt: 0)

        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreAction)
        loadMoreButton.bezelStyle = .rounded
        loadingLabel.textColor = .secondaryLabelColor
        loadMoreButton.setAccessibilityIdentifier("oigo.history.load-more")
        loadingLabel.setAccessibilityIdentifier("oigo.history.loading")
        let footer = NSStackView(views: [loadMoreButton, loadingLabel])
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
            footer.heightAnchor.constraint(equalToConstant: 44),
            listStack.widthAnchor.constraint(equalToConstant: 340)
        ])
        contentView.setAccessibilityIdentifier("oigo.history.content")
        contentView.setAccessibilityLabel("History")
        showMessage("")
        updateLoadingChrome()
    }

    @objc private func loadMoreAction() {
        loadMore()
    }

    private func updateLoadingChrome() {
        loadingLabel.stringValue = isLoading ? "Loading sessions…" : ""
        loadMoreButton.isEnabled = hasMore && !isLoading
        loadMoreButton.isHidden = !hasMore && !isLoading
    }

    private func clampWindowToVisibleFrame() {
        guard let window else {
            return
        }
        let screen = window.screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(window.frame) }) ?? NSScreen.main
        guard let screen else {
            return
        }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(max(frame.width, window.minSize.width), visible.width)
        frame.size.height = min(max(frame.height, window.minSize.height), visible.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        guard frame != window.frame else {
            return
        }
        window.setFrame(frame, display: false)
    }

    private func configureTable() {
        tableView.addTableColumn(column(identifier: "session", title: "", width: 280))
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 82
        tableView.headerView = NSTableHeaderView()
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityIdentifier("oigo.history.table")
        tableView.setAccessibilityLabel("History sessions")
    }

    private func makeDetailView() -> NSView {
        detailTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        detailTitle.setAccessibilityIdentifier("oigo.history.detail-title")
        detailTitle.setAccessibilityLabel("History session date")
        detailTitle.lineBreakMode = .byTruncatingTail
        detailStatus.textColor = .secondaryLabelColor
        detailStatus.font = .systemFont(ofSize: 13)
        detailStatus.setAccessibilityIdentifier("oigo.history.detail-status")
        detailStatus.setAccessibilityLabel("History session status")
        failureLabel.textColor = .systemOrange
        failureLabel.setAccessibilityIdentifier("oigo.history.failure")
        failureLabel.lineBreakMode = .byWordWrapping
        failureLabel.maximumNumberOfLines = 3
        failureLabel.preferredMaxLayoutWidth = 440
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityIdentifier("oigo.history.message")
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2

        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 13)
        transcriptView.setAccessibilityIdentifier("oigo.history.transcript")
        transcriptView.setAccessibilityLabel("Transcript")
        transcriptView.textContainerInset = NSSize(width: 12, height: 12)
        transcriptView.backgroundColor = .textBackgroundColor
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.documentView = transcriptView

        transcriptVersionPopup.addItems(withTitles: ["Raw transcript", "Normalized transcript", "Clean transcript"])
        transcriptVersionPopup.target = self
        transcriptVersionPopup.action = #selector(transcriptVersionAction)
        transcriptVersionPopup.controlSize = .small
        transcriptVersionPopup.toolTip = "Choose which durable transcript version to display"
        transcriptVersionPopup.setAccessibilityIdentifier("oigo.history.transcript-version")
        transcriptVersionPopup.setAccessibilityLabel("Transcript version")

        let stack = NSStackView(
            views: [detailTitle, detailStatus, failureLabel, transcriptVersionPopup, transcriptScroll, messageLabel]
        )
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        transcriptVersionPopup.translatesAutoresizingMaskIntoConstraints = false
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
        let hasNormalized = FileManager.default.fileExists(atPath: entry.session.normalizedTextURL.path)
        let hasClean = FileManager.default.fileExists(atPath: entry.session.cleanTextURL.path)
        transcriptVersionPopup.item(at: 1)?.isEnabled = hasNormalized
        transcriptVersionPopup.item(at: 2)?.isEnabled = hasClean
        if selectedTranscriptSource == .normalized, !hasNormalized {
            selectedTranscriptSource = .raw
        }
        if selectedTranscriptSource == .processed, !hasClean {
            selectedTranscriptSource = hasNormalized ? .normalized : .raw
        }
        let selectedIndex: Int
        let selectedTitle: String
        switch selectedTranscriptSource {
        case .normalized:
            selectedIndex = 1
            selectedTitle = "Normalized transcript"
        case .processed:
            selectedIndex = 2
            selectedTitle = "Clean transcript"
        case .raw:
            selectedIndex = 0
            selectedTitle = "Raw transcript"
        }
        transcriptVersionPopup.selectItem(at: selectedIndex)
        detailStatus.stringValue = Self.statusText(entry.session.metadata.state)
            + " · " + selectedTitle
            + " · " + entry.session.metadata.configurationIdentity.historyLabel
        failureLabel.stringValue = [
            entry.session.metadata.failureReason,
            entry.session.metadata.insertionFailureReason,
            entry.session.metadata.cleanupFallbackReason
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
        transcriptView.string = "Loading transcript…"
        transcriptLoadGeneration &+= 1
        let generation = transcriptLoadGeneration
        let source = selectedTranscriptSource
        loadTranscript(entry, source) { [weak self] result in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.applyTranscriptResult(result, for: entry, generation: generation)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.applyTranscriptResult(result, for: entry, generation: generation)
                }
            }
        }
        setActionButtons(enabled: true, entry: entry)
    }

    private func applyTranscriptResult(
        _ result: Result<String, Error>,
        for entry: SessionHistoryEntry,
        generation: UInt64
    ) {
        guard generation == transcriptLoadGeneration,
              selectedEntry?.id == entry.id else {
            return
        }
        switch result {
        case .success(let transcript):
            transcriptView.string = transcript
        case .failure:
            transcriptView.string = "Transcript unavailable."
            showMessage("Could not load the selected transcript.")
        }
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
        let hasNormalized = entry.map { FileManager.default.fileExists(atPath: $0.session.normalizedTextURL.path) } == true
        let canUseCleanTranscript = canUseTranscript
            && entry.map { FileManager.default.fileExists(atPath: $0.session.cleanTextURL.path) } == true
        transcriptVersionPopup.item(at: 1)?.isEnabled = hasNormalized
        transcriptVersionPopup.item(at: 2)?.isEnabled = canUseCleanTranscript
        transcriptVersionPopup.isEnabled = enabled && entry != nil
        let isPlayingSelection = entry.map { $0.id == playingSessionID } == true
        _ = sessionCommandsEnabled
        _ = isPlayingSelection
        updateToolbarState(for: entry, capabilities: capabilities, canUseTranscript: canUseTranscript)
    }

    private func column(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 0
        return column
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        _ = toolbar
        return [Self.copyToolbarItem, Self.pasteToolbarItem, Self.playbackToolbarItem, Self.moreToolbarItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        _ = toolbar
        _ = flag
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.copyToolbarItem:
            item.label = "Copy"
            item.paletteLabel = "Copy"
            item.toolTip = "Copy the selected transcript"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            item.target = self
            item.action = #selector(copyRawTranscriptAction)
        case Self.pasteToolbarItem:
            item.label = "Paste Again"
            item.paletteLabel = "Paste Again"
            item.image = NSImage(systemSymbolName: "arrow.right.doc.on.clipboard", accessibilityDescription: "Paste Again")
            item.target = self
            item.action = #selector(pasteAgainAction)
        case Self.playbackToolbarItem:
            item.label = "Play"
            item.paletteLabel = "Play or Stop"
            item.image = NSImage(systemSymbolName: "play", accessibilityDescription: "Play")
            item.target = self
            item.action = #selector(playRecordingAction)
        case Self.moreToolbarItem:
            item.label = "More"
            item.paletteLabel = "More"
            item.toolTip = "More recovery actions"
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.target = self
            item.action = #selector(showMoreMenuAction)
            configureMoreMenu()
        default:
            return nil
        }
        toolbarItemsByIdentifier[itemIdentifier] = item
        return item
    }

    @objc private func showMoreMenuAction() {
        guard let contentView = window?.contentView else {
            return
        }
        moreMenu.popUp(
            positioning: nil,
            at: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.maxY - 8),
            in: contentView
        )
    }

    private func configureMoreMenu() {
        guard moreMenu.items.isEmpty else {
            return
        }
        let items: [(String, Selector?)] = [
            ("Copy Raw Transcript", #selector(copyRawTranscriptAction)),
            ("Copy Clean Transcript", #selector(copyCleanTranscriptAction)),
            (NSMenuItem.separator().title, nil),
            ("Clean Again", #selector(cleanAgainAction)),
            ("Reapply Dictionary", #selector(reapplyDictionaryAction)),
            ("Retry Transcription", #selector(retryTranscriptionAction)),
            ("Reveal Recording", #selector(revealRecordingAction)),
            ("Delete Session", #selector(deleteSessionAction))
        ]
        for (title, action) in items {
            if action == nil {
                moreMenu.addItem(.separator())
            } else {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.identifier = NSUserInterfaceItemIdentifier(
                    "oigo.history.action." + title.lowercased().replacingOccurrences(of: " ", with: "-")
                )
                moreMenu.addItem(item)
            }
        }
    }

    private func updateToolbarState(
        for entry: SessionHistoryEntry?,
        capabilities: DictationHistoryCapabilities? = nil,
        canUseTranscript: Bool? = nil
    ) {
        let resolvedCapabilities = capabilities ?? entry.map { item in
            DictationHistoryActions.capabilities(
                sessionState: item.session.metadata.state,
                hasValidRaw: FileManager.default.fileExists(atPath: item.session.rawTextURL.path),
                hasAudio: FileManager.default.fileExists(atPath: item.session.audioURL.path)
            )
        }
        let transcriptAvailable = canUseTranscript ?? (entry != nil && resolvedCapabilities?.copyAvailable == true)
        let cleanAvailable = transcriptAvailable
            && entry.map { FileManager.default.fileExists(atPath: $0.session.cleanTextURL.path) } == true
        let commandsAvailable = commandAvailability?.canPasteAgain ?? true
        toolbarItemsByIdentifier[Self.copyToolbarItem]?.isEnabled = transcriptAvailable
        toolbarItemsByIdentifier[Self.pasteToolbarItem]?.isEnabled = entry != nil
            && resolvedCapabilities?.pasteAgainAvailable == true
            && commandsAvailable
        if let playbackItem = toolbarItemsByIdentifier[Self.playbackToolbarItem] {
            let isPlaying = entry.map { $0.id == playingSessionID } == true
            playbackItem.label = isPlaying ? "Stop" : "Play"
            playbackItem.toolTip = isPlaying ? "Stop playback" : "Play the selected recording"
            playbackItem.image = NSImage(
                systemSymbolName: isPlaying ? "stop.circle" : "play",
                accessibilityDescription: isPlaying ? "Stop" : "Play"
            )
            playbackItem.isEnabled = entry != nil && (
                isPlaying
                    || entry.map { FileManager.default.fileExists(atPath: $0.session.audioURL.path) } == true
            )
        }
        moreMenu.item(withTitle: "Copy Raw Transcript")?.isEnabled = transcriptAvailable
        moreMenu.item(withTitle: "Copy Clean Transcript")?.isEnabled = cleanAvailable
        moreMenu.item(withTitle: "Clean Again")?.isEnabled = transcriptAvailable
            && cleanAgainOverride
            && (commandAvailability?.canCleanAgain ?? true)
        moreMenu.item(withTitle: "Reapply Dictionary")?.isEnabled = transcriptAvailable
            && (commandAvailability?.canReapplyDictionary ?? true)
        moreMenu.item(withTitle: "Retry Transcription")?.isEnabled = entry != nil
            && resolvedCapabilities?.savedAudioRetryAvailable == true
            && (commandAvailability?.canRetry ?? true)
        moreMenu.item(withTitle: "Reveal Recording")?.isEnabled = entry.map {
            FileManager.default.fileExists(atPath: $0.session.audioURL.path)
        } == true
        moreMenu.item(withTitle: "Delete Session")?.isEnabled = entry?.session.metadata.state.isUnfinished == false
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

@MainActor
private final class HistorySessionRowView: NSTableCellView {
    func configure(projection: OigoHistoryRowProjection, dateFormatter: DateFormatter) {
        subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(
            wrappingLabelWithString: dateFormatter.string(from: projection.date)
                + "  ·  " + (projection.duration.map(Self.durationText) ?? "")
                + "  ·  " + projection.statusLabel
                + "\n" + projection.summary
        )
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        setAccessibilityLabel(projection.accessibilityLabel)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
