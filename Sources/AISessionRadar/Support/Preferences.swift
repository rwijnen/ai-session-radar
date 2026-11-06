import Foundation

/// The app's own settings, kept in its defaults. Settings the Python side also reads
/// (pull requests) live in `RadarConfig` instead.
final class Preferences: ObservableObject {
    private enum Key {
        static let checkForUpdates = "checkForUpdates"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let setupDone = "setupDone"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.checkForUpdates: true])
        checkForUpdates = defaults.bool(forKey: Key.checkForUpdates)
        skippedUpdateVersion = defaults.string(forKey: Key.skippedUpdateVersion)
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck) as? Date
        setupDone = defaults.bool(forKey: Key.setupDone)
    }

    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }

    /// Release tag the user asked not to be reminded about. A later release is offered as normal.
    var skippedUpdateVersion: String? {
        didSet { defaults.set(skippedUpdateVersion, forKey: Key.skippedUpdateVersion) }
    }

    var lastUpdateCheck: Date? {
        didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) }
    }

    /// The welcome window was closed once; afterwards it only opens again when something is missing.
    var setupDone: Bool {
        didSet { defaults.set(setupDone, forKey: Key.setupDone) }
    }
}
