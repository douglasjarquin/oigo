import Foundation

final class PopoverRoutingScenario: NativeUIContractScenario {
    private struct Fixture: Decodable {
        struct Route: Decodable {
            let event: String
            let opens: String
            let closes: String?
        }

        let name: String
        let generation: UInt64
        let staleGeneration: UInt64
        let routes: [Route]
        let menuEntries: [String]
        let popoverWidth: Int
        let transient: Bool
        let appActivation: String
        let monitorsAfterTeardown: Int
        let observersAfterTeardown: Int
        let dirty: Bool
        let reportedSuccess: Bool
        let processExitStatus: Int
    }

    override class var scenarioName: String {
        "popover-routing"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task11" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }
        let fixture = try loadFixture(arguments.fixtureRoot.appendingPathComponent("fixture.json"))
        try validate(fixture)
        try validateProductSource()
        print(
            "PASS popover-routing fixture=" + fixture.name
                + " routes=3 menu=history,settings,separator,quit surfaces=exclusive"
                + " activation=accessory stale=fenced resources=0"
        )
    }

    private static func loadFixture(_ url: URL) throws -> Fixture {
        guard let data = try? Data(contentsOf: url) else {
            throw ContractInputError(category: "missing-fixture")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ContractInputError(category: "malformed-popover-routing-fixture")
        }
        if containsPrivateContent(object) {
            throw ContractInputError(category: "forbidden-user-content")
        }
        do {
            return try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            throw ContractInputError(category: "malformed-popover-routing-fixture")
        }
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.name == "primary-secondary-control-click",
              fixture.routes.map(\.event) == ["primary", "secondary", "control-primary"],
              fixture.routes.map(\.opens) == ["popover", "utility-menu", "utility-menu"],
              fixture.routes.map(\.closes) == ["utility-menu", "popover", "popover"],
              fixture.menuEntries == ["History", "Settings", "separator", "Quit"],
              (330...350).contains(fixture.popoverWidth),
              fixture.transient,
              fixture.appActivation == "accessory-no-frontmost-after-dismissal",
              fixture.monitorsAfterTeardown == 0,
              fixture.observersAfterTeardown == 0 else {
            throw ContractInputError(category: "incomplete-routing-matrix")
        }
        guard fixture.staleGeneration < fixture.generation else {
            throw ContractInputError(category: "invalid-stale-generation-fixture")
        }
        guard !fixture.dirty else {
            throw ContractInputError(category: "dirty-worktree")
        }
        if fixture.reportedSuccess, fixture.processExitStatus != 0 {
            print("PASS decoy-only")
            throw ContractInputError(category: "misleading-success-output")
        }
    }

    private static func validateProductSource() throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controllerURL = repository.appendingPathComponent("Sources/Oigo/StatusSurfaceController.swift")
        let delegateURL = repository.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift")
        guard let controller = try? String(contentsOf: controllerURL, encoding: .utf8),
              let delegate = try? String(contentsOf: delegateURL, encoding: .utf8) else {
            throw ContractInputError(category: "unreadable-routing-source")
        }

        let requiredControllerTokens = [
            "enum OigoStatusSurfaceCommand", "case history", "case settings", "case quit",
            "NSPopover()", ".behavior = .transient", "width: 340", ".leftMouseUp",
            ".rightMouseUp", ".control", "cancelTracking()", "popover.close()",
            "func publish(_ state: OigoPresentationState, generation: UInt64)",
            "guard generation > presentationGeneration", "func teardown()"
        ]
        guard requiredControllerTokens.allSatisfy(controller.contains) else {
            throw ContractInputError(category: "missing-product-routing")
        }
        let requiredMenuOrder = [
            "title: \"History\"", "title: \"Settings\"", "addItem(.separator())",
            "title: \"Quit\""
        ]
        guard appearsInOrder(requiredMenuOrder, in: controller) else {
            throw ContractInputError(category: "invalid-utility-menu")
        }
        let forbidden = [
            "addGlobalMonitorForEvents", "OigoSettingsStore", "SessionStore", "transcript",
            "AppOperationGate", "frontmostApplication", "DispatchQueue.main.asyncAfter"
        ]
        guard !forbidden.contains(where: controller.contains) else {
            throw ContractInputError(category: "forbidden-routing-dependency")
        }
        guard delegate.contains("statusSurface.install(statusItem: item)"),
              delegate.contains("statusSurface.publish(publication.state, generation: publication.generation)"),
              delegate.contains("statusSurface.teardown()"),
              !delegate.contains("item.menu = menu") else {
            throw ContractInputError(category: "delegate-routing-seam-missing")
        }
    }

    private static func appearsInOrder(_ needles: [String], in source: String) -> Bool {
        var remainder = source[source.startIndex...]
        for needle in needles {
            guard let range = remainder.range(of: needle) else {
                return false
            }
            remainder = remainder[range.upperBound...]
        }
        return true
    }

    private static func containsPrivateContent(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            let forbidden = Set([
                "audio", "clipboard", "dictionaryEntries", "focusedText", "microphone",
                "pasteboard", "sessionBody", "transcript", "userPath"
            ])
            return !forbidden.isDisjoint(with: dictionary.keys)
                || dictionary.values.contains(where: containsPrivateContent)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsPrivateContent)
        }
        return false
    }
}
