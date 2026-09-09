import AppKit
import OigoCore

@MainActor
extension SettingsWindowController {
    func task28BeginLocaleSaveForTesting(_ identifier: String) -> OigoLocaleAssetReadiness? {
        if !localeSelection.hasLoadedSupported { localeSelection.loadSupported(["en-US", "es-MX"]) }
        localeSelection.select(identifier)
        syncLocalePopup()
        dictationMessage.stringValue = localeSelection.statusMessage
        guard let request = localeSelection.beginAssetRequest(status: .installing) else { return nil }
        isCheckingLocale = true
        return request
    }
    @discardableResult
    func task28CompleteLocaleSaveForTesting(_ request: OigoLocaleAssetReadiness, status: OigoLocaleAssetStatus) -> Bool {
        let applied = localeSelection.applyAssetResult(
            localeIdentifier: request.localeIdentifier, generation: request.generation, status: status
        )
        isCheckingLocale = false
        guard applied, localeSelection.canConfirm, let locale = localeSelection.selectedIdentifier else {
            if applied { localeSelection.abandonUncommitted(); syncLocalePopup() }
            _ = finishSave(committedSettings, languageUnappliedMessage: "Settings saved. Dictation language was not changed.")
            return false
        }
        guard finishSave(committedSettings.with(localeIdentifier: locale), languageUnappliedMessage: nil) else { return false }
        _ = localeSelection.confirm()
        return true
    }
    func task28DictionaryEntriesForTesting() -> [DictionaryEntry] { dictionaryEntries }
}
