import AppKit

@MainActor
public final class MacUITranscriptView: NSScrollView {
    private let textView: NSTextView
    public let maximumLength: Int
    public var transcript: String {
        textView.string
    }

    public init(maximumLength: Int = 20_000) {
        self.maximumLength = max(1, maximumLength)
        textView = NSTextView(frame: .zero)
        super.init(frame: .zero)

        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        drawsBackground = true
        documentView = textView

        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
    }

    public func setTranscript(_ transcript: String) {
        textView.string = String(transcript.prefix(maximumLength))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    public func clear() {
        textView.string = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
