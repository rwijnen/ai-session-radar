import Foundation

enum AppBundle {
    /// Whether this process is a real `.app`.
    ///
    /// Worth checking before calling several system frameworks, because they do not fail
    /// politely: `SMAppService` and `UNUserNotificationCenter.current()` both raise an
    /// Objective-C exception — `bundleProxyForCurrentProcess is nil` — which Swift cannot
    /// catch, so it takes the whole process down. That is the case when the binary is run
    /// straight out of `.build`, which is exactly what `swift run` does.
    static var isApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}
