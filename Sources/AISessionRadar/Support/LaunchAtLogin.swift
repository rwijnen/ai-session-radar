import Foundation
import ServiceManagement

/// Login-item registration.
///
/// `SMAppService` reads the running bundle's identity and it is unforgiving about it:
/// touching `mainApp` from a process that is not a real `.app` raises an Objective-C
/// exception — `bundleProxyForCurrentProcess is nil` — which Swift cannot catch, so it
/// takes the app down. That is exactly what happens when the binary is run straight out of
/// `.build` during development, so every entry point here checks first and the toggle
/// disables itself instead.
enum LaunchAtLogin {
    static var isAvailable: Bool { AppBundle.isApp }

    static var isEnabled: Bool {
        AppBundle.isApp && SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, so a failed toggle snaps back instead of lying.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard AppBundle.isApp else {
            Log.app.error("launch at login needs an installed .app; ignoring")
            return false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("could not \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}
