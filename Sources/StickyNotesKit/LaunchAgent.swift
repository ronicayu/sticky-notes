import ServiceManagement

enum LaunchAgent {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isAvailable: Bool {
        // SMAppService.mainApp registration only works for properly bundled apps.
        // It fails when the binary is launched directly (e.g. via `swift run`).
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// True when the user previously switched the app off in System Settings.
    /// `register()` succeeds in that state without actually enabling anything,
    /// so only System Settings can undo it.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static let loginItemsSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
