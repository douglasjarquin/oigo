import Foundation
import OigoCore
@_spi(Testing) import OigoCapture

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
            ("settings-migration", testSettingsMigration),
            ("menu-and-unavailable", testMenuAndUnavailable),
            ("route-before-format", testRouteBeforeFormat),
            ("missing-pinned-no-fallback", testMissingPinnedNoFallback),
            ("recording-operation-fence", testRecordingOperationFence),
            ("callback-delivery-gate", testCallbackDeliveryGate)
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

    private static func testMenuAndUnavailable() throws {
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
                uid: "uid-a",
                displayName: "USB Mic",
                deviceID: 1,
                inputChannelCount: 1,
                nominalSampleRate: 44_100,
                isAlive: true,
                isDefault: true
            )
        ]

        let items = OigoInputMenu.items(
            devices: devices,
            selected: .pinned(uid: "uid-missing")
        )
        guard items.first?.title == "System Default",
              items.filter({ $0.title == "USB Mic" }).count == 2,
              items.contains(where: { $0.isUnavailable && $0.title.contains("Unavailable") }),
              items.allSatisfy({ !$0.title.contains("uid-") }) else {
            throw ContractFailure(message: "input menu did not expose every local input, preserve duplicate names, or annotate a missing pinned device safely")
        }
    }

    private static func testRouteBeforeFormat() throws {
        let device = OigoInputDevice(
            uid: "uid-pinned",
            displayName: "Pinned Mic",
            deviceID: 12,
            inputChannelCount: 1,
            nominalSampleRate: 48_000,
            isAlive: true,
            isDefault: false
        )
        var events: [String] = []
        _ = try OigoInputDeviceCatalog.resolveAndRouteBeforeInspection(
            .pinned(uid: device.uid),
            from: [device],
            route: { routedDevice in
                guard routedDevice.deviceID == device.deviceID else {
                    throw ContractFailure(message: "pinned route used a transient device ID from another device")
                }
                events.append("route")
            },
            inspect: { _ in
                events.append("inspect-format")
            }
        )
        guard events == ["route", "inspect-format"] else {
            throw ContractFailure(message: "format inspection was not ordered after pinned-device routing")
        }
    }

    private static func testMissingPinnedNoFallback() throws {
        let defaultDevice = OigoInputDevice(
            uid: "uid-default",
            displayName: "Default Mic",
            deviceID: 1,
            inputChannelCount: 1,
            nominalSampleRate: 48_000,
            isAlive: true,
            isDefault: true
        )
        var routed = false
        do {
            _ = try OigoInputDeviceCatalog.resolveAndRoute(
                .pinned(uid: "uid-missing"),
                from: [defaultDevice],
                route: { _ in routed = true }
            )
            throw ContractFailure(message: "a missing pinned input silently fell back to the default microphone")
        } catch let error as OigoInputDeviceResolutionError {
            guard error == .pinnedInputUnavailable,
                  !routed,
                  !error.description.contains("uid-missing"),
                  !error.description.contains("Default Mic") else {
                throw ContractFailure(message: "missing pinned input did not fail closed with a privacy-safe actionable error")
            }
        }
    }

    private static func testRecordingOperationFence() throws {
        var fence = AudioRecordingOperationFence()
        let firstGeneration = fence.begin()
        guard fence.accepts(firstGeneration) else {
            throw ContractFailure(message: "new recording operation did not accept its own callback generation")
        }

        fence.invalidate()
        let secondGeneration = fence.begin()
        guard !fence.accepts(firstGeneration),
              fence.accepts(secondGeneration) else {
            throw ContractFailure(message: "stale recording callback generation was not rejected after teardown")
        }
    }

    private static func testCallbackDeliveryGate() throws {
        let gate = AudioRecordingCallbackGate()
        let state = CallbackGateTestState()
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let invalidationReady = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = gate.deliverIfAllowed(
                state.isAllowedForDelivery,
                {
                    callbackStarted.signal()
                    releaseCallback.wait()
                    state.markDelivered()
                }
            )
        }
        guard callbackStarted.wait(timeout: .now() + 1) == .success else {
            throw ContractFailure(message: "callback delivery did not acquire its gate")
        }

        DispatchQueue.global().async {
            invalidationReady.signal()
            gate.performExclusively {
                state.invalidate()
            }
            invalidationFinished.signal()
        }
        guard invalidationReady.wait(timeout: .now() + 1) == .success else {
            throw ContractFailure(message: "callback invalidation did not start")
        }
        releaseCallback.signal()
        guard invalidationFinished.wait(timeout: .now() + 1) == .success else {
            throw ContractFailure(message: "callback invalidation did not complete")
        }
        guard state.wasDelivered,
              state.callbackFinishedBeforeInvalidation else {
            throw ContractFailure(message: "callback delivery raced teardown instead of serializing with it")
        }

        let deliveredAfterInvalidation = gate.deliverIfAllowed(
            state.isAllowedForDelivery,
            {
                state.clearDelivered()
            }
        )
        guard !deliveredAfterInvalidation, state.wasDelivered else {
            throw ContractFailure(message: "stale callback delivered after invalidation")
        }
    }

    private final class CallbackGateTestState: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true
        private var delivered = false
        private var finishedBeforeInvalidation = false

        var wasDelivered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return delivered
        }

        var callbackFinishedBeforeInvalidation: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finishedBeforeInvalidation
        }

        func isAllowedForDelivery() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return allowed
        }

        func markDelivered() {
            lock.lock()
            delivered = true
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            allowed = false
            finishedBeforeInvalidation = delivered
            lock.unlock()
        }

        func clearDelivered() {
            lock.lock()
            delivered = false
            lock.unlock()
        }
    }
}
