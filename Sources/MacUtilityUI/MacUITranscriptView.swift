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
        textView.backgroundColor = MacUITokens.Colors.textBackground
        textView.textColor = MacUITokens.Colors.primaryLabel
        textView.font = MacUITokens.Typography.body
        textView.textContainerInset = NSSize(width: MacUITokens.Spacing.controlGroup, height: MacUITokens.Spacing.controlGroup)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        MacUIAccessibility.configure(
            self,
            identifier: "macui.transcript",
            label: "Transcript",
            role: .textArea
        )
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
