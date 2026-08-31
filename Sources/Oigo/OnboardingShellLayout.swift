import AppKit

@available(macOS 26.0, *)
@MainActor
enum OigoOnboardingShellLayout {
    static func configureProgress(
        _ progressStages: NSStackView,
        titles: [String]
    ) -> [NSTextField] {
        progressStages.orientation = .horizontal
        progressStages.alignment = .centerY
        progressStages.distribution = .fillEqually
        progressStages.spacing = 8
        progressStages.translatesAutoresizingMaskIntoConstraints = false
        return titles.enumerated().map { index, title in
            let label = NSTextField(labelWithString: String(index + 1) + "  " + title)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let identifier = "oigo.onboarding.progress.stage-" + String(index + 1)
            label.identifier = NSUserInterfaceItemIdentifier(identifier)
            label.setAccessibilityIdentifier(identifier)
            label.setAccessibilityRole(.staticText)
            label.setAccessibilityLabel("Stage " + String(index + 1) + ". " + title)
            progressStages.addArrangedSubview(label)
            return label
        }
    }

    static func install(
        window: NSWindow,
        contentView: NSView,
        chromeTitleLabel: NSTextField,
        progressStages: NSStackView,
        stack: NSStackView,
        backButton: NSButton,
        nextButton: NSButton
    ) {
        window.title = OigoOnboardingShellMetrics.title
        chromeTitleLabel.stringValue = OigoOnboardingShellMetrics.title
        chromeTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        chromeTitleLabel.alignment = .center
        chromeTitleLabel.textColor = .labelColor
        chromeTitleLabel.identifier = NSUserInterfaceItemIdentifier("oigo.onboarding.chrome-title")
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
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let chrome = NSView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        chrome.setAccessibilityRole(.group)
        chrome.setAccessibilityIdentifier("oigo.onboarding.chrome")
        chrome.setAccessibilityLabel("Set Up Oigo window header")
        chrome.addSubview(chromeTitleLabel)
        contentView.addSubview(chrome)

        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: contentView.topAnchor),
            chrome.heightAnchor.constraint(equalToConstant: OigoOnboardingShellMetrics.chromeHeight),
            chromeTitleLabel.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 12),
            chromeTitleLabel.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -12),
            chromeTitleLabel.centerYAnchor.constraint(equalTo: chrome.centerYAnchor)
        ])

        let buttons = stack.arrangedSubviews.last!
        (buttons as? NSStackView)?.spacing = 8
        (buttons as? NSStackView)?.alignment = .trailing
        NSLayoutConstraint.activate([
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
                equalTo: contentView.bottomAnchor,
                constant: -OigoOnboardingShellMetrics.contentVerticalPadding
            ),
            progressStages.widthAnchor.constraint(equalTo: stack.widthAnchor),
            backButton.superview!.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        _ = window
    }
}
