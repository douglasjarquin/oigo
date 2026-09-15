import AppKit
import OigoCore

@MainActor
extension HistoryWindowController {
    func task29TableViewForTesting() -> NSTableView { tableView }
    func task29MoreMenuTitlesForTesting() -> [String] { moreMenu.items.filter { !$0.isSeparatorItem }.map(\.title) }
    func task29MoreMenuItemForTesting(title: String) -> NSMenuItem? { moreMenu.item(withTitle: title) }
    func task29MoreMenuSnapshotForTesting() -> [(identifier: String, title: String, isEnabled: Bool)] {
        moreMenu.items.filter { !$0.isSeparatorItem }.map {
            (identifier: $0.identifier?.rawValue ?? "", title: $0.title, isEnabled: $0.isEnabled)
        }
    }
    func task29MeasuredGeometryForTesting() -> (toolbarHeight: CGFloat, mainRegionHeight: CGFloat) {
        guard window?.toolbar != nil, let toolbarView = task29ToolbarView(),
              let platterView = task29ToolbarPlatter(in: toolbarView), let mainRegionView else {
            return (0, 0)
        }
        return (toolbarView.bounds.height - platterView.frame.minY, mainRegionView.frame.height)
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
        transcriptVersionPopup.selectItem(at: source == .raw ? 0 : source == .normalized ? 1 : 2)
        guard let action = transcriptVersionPopup.action else { return }
        _ = NSApp.sendAction(action, to: transcriptVersionPopup.target, from: transcriptVersionPopup)
    }
    func task29LoadingLabelForTesting() -> String { loadingLabel.stringValue }
    func task29LoadMoreButtonForTesting() -> NSButton { loadMoreButton }
    func task30InvokePasteAgainForTesting() {
        guard let item = window?.toolbar?.items.first(where: {
            $0.itemIdentifier == NSToolbarItem.Identifier("com.oigo.history.paste-again")
        }), let action = item.action else { return }
        _ = NSApp.sendAction(action, to: item.target, from: item)
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
}
