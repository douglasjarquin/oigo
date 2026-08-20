import OigoCore
import ServiceManagement

@MainActor
final class SystemLaunchAtLoginClient: OigoLaunchAtLoginClient {
    private let service = SMAppService.mainApp

    var status: OigoLaunchAtLoginStatus {
        switch service.status {
        case .enabled:
            .enabled
        case .notRegistered:
            .disabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unknown
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
