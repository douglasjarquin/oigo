import Foundation

final class GalleryComponentsScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        struct Component: Decodable {
            let id: String
            let accessibilityRole: String
            let accessibilityLabel: String
            let accessibilityActions: [String]
            let focusOrder: Int?
            let keyActivations: [String]
        }

        struct Panel: Decodable {
            let nonactivating: Bool
            let canBecomeKey: Bool
            let canBecomeMain: Bool
        }

        struct Lifecycle: Decodable {
            let transcriptClearable: Bool
            let loadingStops: Bool
            let panelTerminalizes: Bool
        }

        struct Result: Decodable {
            let reportedSuccess: Bool
            let processExitStatus: Int
        }

        let scenarios: [String]
        let appearanceStates: [String]
        let textSizes: [String]
        let reducedMotion: Bool
        let pasteboardProvider: String
        let permissionProvider: String
        let components: [Component]
        let panel: Panel
        let lifecycle: Lifecycle
        let focusObservations: [[String]]
        let dirty: Bool?
        let result: Result?
    }

    override class var scenarioName: String {
        "gallery-components"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task7" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(from: arguments.fixtureRoot)
        try validate(fixture)
        print(
            "PASS gallery-components scenarios=\(fixture.scenarios.count) "
                + "components=\(fixture.components.count) focus=deterministic"
        )
    }

    private static func loadFixture(from root: URL) throws -> Fixture {
        let url = root.appendingPathComponent("fixture.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-gallery-metadata")
        }
        if containsPrivateContent(in: object) {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-gallery-metadata")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        if fixture.dirty == true {
            throw ContractInputError(category: "dirty-worktree")
        }
        if let result = fixture.result,
           result.reportedSuccess,
           result.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
        guard fixture.scenarios == fixture.scenarios.sorted(),
              Set(fixture.scenarios).count == fixture.scenarios.count,
              fixture.scenarios == ["components"] else {
            throw ContractInputError(category: "unsorted-or-duplicate-scenarios")
        }
        guard fixture.appearanceStates == ["light", "dark"],
              fixture.textSizes == ["normal", "large"],
              fixture.reducedMotion,
              fixture.pasteboardProvider == "synthetic",
              fixture.permissionProvider == "synthetic" else {
            throw ContractInputError(category: "incomplete-gallery-matrix")
        }

        let requiredComponents = Set([
            "destructive-confirmation", "empty-state", "field-help-text", "floating-panel",
            "form-row", "inline-notice", "loading-state", "permission-row", "section-header",
            "shortcut-presentation", "status-badge", "status-row", "storage-health-row",
            "transcript-view"
        ])
        let componentsByID = Dictionary(grouping: fixture.components, by: \.id)
        guard Set(componentsByID.keys) == requiredComponents,
              componentsByID.values.allSatisfy({ $0.count == 1 }) else {
            throw ContractInputError(category: "incomplete-component-set")
        }
        guard fixture.components.allSatisfy({
            !$0.accessibilityRole.isEmpty && !$0.accessibilityLabel.isEmpty
        }) else {
            throw ContractInputError(category: "invalid-accessibility-metadata")
        }

        let actionable = [
            "destructive-confirmation", "inline-notice", "permission-row", "storage-health-row",
            "transcript-view"
        ]
        let focusable = actionable.compactMap { componentsByID[$0]?.first }
        guard focusable.allSatisfy({ $0.accessibilityActions.contains("press") }),
              focusable.allSatisfy({ $0.keyActivations == ["Return", "Space"] }),
              focusable.compactMap(\.focusOrder) == Array(1...actionable.count) else {
            throw ContractInputError(category: "invalid-keyboard-contract")
        }
        guard fixture.focusObservations.count == 2,
              Set(fixture.focusObservations.map { $0.joined(separator: "|") }).count == 1,
              fixture.focusObservations.first == actionable else {
            throw ContractInputError(category: "flaky-focus-order")
        }
        guard fixture.panel.nonactivating,
              !fixture.panel.canBecomeKey,
              !fixture.panel.canBecomeMain,
              fixture.lifecycle.transcriptClearable,
              fixture.lifecycle.loadingStops,
              fixture.lifecycle.panelTerminalizes else {
            throw ContractInputError(category: "invalid-component-lifecycle")
        }
    }

    private static func containsPrivateContent(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "audio", "clipboard", "dictionaryEntries", "focusedText", "microphone",
                "pasteboard", "productionData", "transcript", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsPrivateContent(in:))
        }
        if let array = object as? [Any] {
            return array.contains(where: containsPrivateContent(in:))
        }
        return false
    }
}
