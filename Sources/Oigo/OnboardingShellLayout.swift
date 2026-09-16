import AppKit
import MacUtilityUI

@available(macOS 26.0, *)
@MainActor
enum OigoOnboardingShellLayout {
    static func configureTrailingRow(_ row: NSStackView, label: NSTextField, control: NSView) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacUITokens.Spacing.controlGroup
        label.font = MacUITokens.Typography.label
        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(control)
        label.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
    }

    static func configureCard(_ card: NSBox, rows: NSStackView) {
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.cornerRadius = MacUITokens.Radius.contained
        card.fillColor = MacUITokens.Colors.controlBackground
        card.borderColor = MacUITokens.Colors.separator
        card.borderWidth = 0.5
        card.contentViewMargins = NSSize(width: 14, height: 0)
        card.contentView = rows
        card.setAccessibilityIdentifier("oigo.onboarding.detail-card")
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
    }

    static func addCardRow(_ row: NSView, to rows: NSStackView) {
        if !rows.arrangedSubviews.isEmpty {
            let separator = NSBox()
            separator.boxType = .separator
            rows.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let container = NSStackView(views: [row])
        container.orientation = .vertical
        container.edgeInsets = NSEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        rows.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    static func install(
        window: NSWindow,
        contentView: NSView,
        chromeTitleLabel: NSTextField,
        stack: NSStackView,
        skipButton: NSButton,
        backButton: NSButton,
        nextButton: NSButton
    ) {
        window.title = OigoOnboardingShellMetrics.title
        chromeTitleLabel.stringValue = OigoOnboardingShellMetrics.title
        chromeTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        chromeTitleLabel.alignment = .center
        chromeTitleLabel.textColor = .labelColor
        chromeTitleLabel.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.chrome-title")
        chromeTitleLabel.setAccessibilityIdentifier("oigo.onboarding.chrome-title")
        chromeTitleLabel.setAccessibilityRole(.staticText)
        chromeTitleLabel.setAccessibilityLabel(OigoOnboardingShellMetrics.title)
        backButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.back")
        backButton.setAccessibilityIdentifier("oigo.onboarding.back")
        backButton.bezelStyle = .rounded
        backButton.setAccessibilityLabel("Back")
        nextButton.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.continue")
        nextButton.setAccessibilityIdentifier("oigo.onboarding.continue")
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.setAccessibilityLabel("Continue")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = MacUITokens.Spacing.row
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        chromeTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let chrome = NSView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.setAccessibilityRole(.group)
        chrome.setAccessibilityIdentifier("oigo.onboarding.chrome")
        chrome.setAccessibilityLabel("Set Up Oigo window header")
        chrome.addSubview(chromeTitleLabel)
        contentView.addSubview(chrome)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: OigoOnboardingShellMetrics.windowWidth),
            chrome.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: contentView.topAnchor),
            chrome.heightAnchor.constraint(equalToConstant: OigoOnboardingShellMetrics.chromeHeight),
            chromeTitleLabel.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 12),
            chromeTitleLabel.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -12),
            chromeTitleLabel.centerYAnchor.constraint(equalTo: chrome.centerYAnchor)
        ])

        let buttons = NSStackView(views: [skipButton, NSView(), backButton, nextButton])
        buttons.spacing = MacUITokens.Spacing.controlGroup
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setAccessibilityIdentifier("oigo.onboarding.footer")
        contentView.addSubview(buttons)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            buttons.heightAnchor.constraint(equalToConstant: OigoOnboardingShellMetrics.footerHeight),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttons.topAnchor),
            stack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: OigoOnboardingShellMetrics.contentHorizontalPadding
            ),
            stack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -OigoOnboardingShellMetrics.contentHorizontalPadding
            ),
            stack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: OigoOnboardingShellMetrics.chromeHeight
                    + OigoOnboardingShellMetrics.contentVerticalPadding
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: buttons.topAnchor,
                constant: -OigoOnboardingShellMetrics.contentVerticalPadding
            )
        ])
        _ = window
    }
}
