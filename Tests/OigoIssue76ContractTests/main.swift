import Foundation
import OigoCore

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
private struct OigoIssue76ContractTests {
    static func main() {
        let filter = CommandLine.arguments.dropFirst().drop(while: { $0 != "--filter" }).dropFirst().first
        let tests: [(String, () throws -> Void)] = [
            ("inventory-and-selection", testInventoryAndSelection),
            ("settings-migration", testSettingsMigration)
        ]

        let selected = tests.filter { filter == nil || $0.0.contains(filter ?? "") }
        guard !selected.isEmpty else {
            print("FAIL: no issue #76 contract scenarios matched filter")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try test()
                print("GREEN: issue #76 " + name)
            } catch {
                failures += 1
                print("FAIL: issue #76 " + name + ": " + String(describing: error))
            }
        }

        if failures > 0 {
            print("FAILURES=" + String(failures))
            exit(1)
        }
        print("GREEN: all issue #76 contract scenarios")
    }

    private static func testInventoryAndSelection() throws {
        let devices = [
            OigoInputDevice(
                uid: "uid-z",
                displayName: "USB Mic",
                deviceID: 2,
                inputChannelCount: 2,
                nominalSampleRate: 48_000,
                isAlive: true,
                isDefault: false
            ),
            OigoInputDevice(
                uid: "uid-empty",
                displayName: "Output Only",
                deviceID: 3,
                inputChannelCount: 0,
                nominalSampleRate: 48_000,
                isAlive: true,
                isDefault: false
            ),
            OigoInputDevice(
                uid: "uid-a",
                displayName: "USB Mic",
                deviceID: 1,
                inputChannelCount: 1,
                nominalSampleRate: 44_100,
                isAlive: true,
                isDefault: true
            ),
            OigoInputDevice(
                uid: "uid-dead",
                displayName: "Disconnected",
                deviceID: 4,
                inputChannelCount: 1,
                nominalSampleRate: 48_000,
                isAlive: false,
                isDefault: false
            )
        ]

        let visible = OigoInputDeviceCatalog.visibleDevices(from: devices)
        guard visible.map(\.uid) == ["uid-a", "uid-z"] else {
            throw ContractFailure(message: "inventory did not filter unavailable/non-input devices and sort duplicate names deterministically")
        }
        guard try OigoInputDeviceCatalog.resolve(.systemDefault, from: visible).uid == "uid-a" else {
            throw ContractFailure(message: "System Default did not resolve to the current default input")
        }
        guard try OigoInputDeviceCatalog.resolve(.pinned(uid: "uid-z"), from: visible).deviceID == 2 else {
            throw ContractFailure(message: "pinned selection did not resolve by stable UID to the current device ID")
        }
    }

    private static func testSettingsMigration() throws {
        let suiteName = "oigo-issue76-settings-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ContractFailure(message: "could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldJSON: [String: Any] = [
            "globalShortcut": ["keyCode": 49, "modifiers": 2304],
            "localeIdentifier": "en-US",
            "defaultMode": "clean",
            "showVolatilePreview": false,
            "audioRetention": "oneWeek",
            "keepSuccessfulAudioIndefinitely": true,
            "launchAtLogin": true
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: oldJSON), forKey: "oigo.settings.v1")

        let loaded = OigoSettingsStore(defaults: defaults).load()
        guard loaded.localeIdentifier == "en-US",
              loaded.defaultMode == .clean,
              loaded.showVolatilePreview == false,
              loaded.audioRetention == .oneWeek,
              loaded.keepSuccessfulAudioIndefinitely,
              loaded.launchAtLogin else {
            throw ContractFailure(message: "existing settings were not preserved during input-selection migration")
        }

        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(loaded)
        ) as? [String: Any]
        let selectedInput = encoded?["selectedInput"] as? [String: Any]
        guard selectedInput?["kind"] as? String == "systemDefault" else {
            throw ContractFailure(message: "legacy settings did not migrate to explicit System Default input selection")
        }
    }
}
