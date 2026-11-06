import AppKit
import Foundation

/// Looks for a newer AI Session Radar on GitHub Releases and offers to install it.
///
/// Automatic checks are quiet: they only speak up when there is something to install, and
/// a version the user chose to skip stays skipped. A check the user asked for always
/// answers, including "you are up to date" and any error.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case installing
        case failed(String)
    }

    static let repository = "rwijnen/ai-session-radar"

    /// Once a day is plenty for a tool that releases a few times a year, and stays far
    /// inside GitHub's limit of 60 unauthenticated requests an hour.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?

    /// `nil` when running outside a bundle, as `swift run` does — there is no version to
    /// compare and nothing to replace.
    let currentVersion: AppVersion?
    private let preferences: Preferences
    private let session: URLSession
    private var timer: Timer?

    init(preferences: Preferences, session: URLSession = .shared) {
        self.preferences = preferences
        self.session = session
        lastChecked = preferences.lastUpdateCheck
        currentVersion = AppBundle.isApp
            ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                .flatMap(AppVersion.init)
            : nil
    }

    var isAvailable: Bool { currentVersion != nil }

    var availableRelease: GitHubRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    // MARK: - Scheduling

    func start() {
        guard isAvailable else { return }
        // Hourly, but each tick only checks once the last check is a day old — so a Mac
        // that sleeps through the scheduled moment still checks soon after waking.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Shortly after launch rather than during it, while the first refreshes run.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard preferences.checkForUpdates else { return }
        if let last = preferences.lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        Task { await check(userInitiated: false) }
    }

    /// For the menu and Settings. Always reports back, whatever the outcome.
    func checkNow() {
        if let release = availableRelease {
            offer(release, userInitiated: true)
        } else {
            Task { await check(userInitiated: true) }
        }
    }

    // MARK: - Checking

    private func check(userInitiated: Bool) async {
        guard let currentVersion, status != .checking, status != .installing else { return }
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            let now = Date()
            lastChecked = now
            preferences.lastUpdateCheck = now

            guard let release, let version = release.version, version > currentVersion else {
                status = .upToDate
                if userInitiated { showUpToDate(currentVersion) }
                return
            }
            status = .available(release)
            Log.app.info("update available: \(version.description, privacy: .public)")
            if userInitiated || preferences.skippedUpdateVersion != release.tagName {
                offer(release, userInitiated: userInitiated)
            }
        } catch {
            status = .failed(error.localizedDescription)
            Log.app.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated {
                showError("Could not check for updates", error.localizedDescription, page: nil)
            }
        }
    }

    /// `nil` when the repository has no published release yet, which GitHub reports as
    /// a 404 — that is "nothing newer", not a failure.
    private func fetchLatestRelease() async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AISessionRadar/\(currentVersion?.description ?? "0")", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard (200..<300).contains(code) else {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "GitHub answered with status \(code).",
            ])
        }
        return try GitHubRelease.decode(data)
    }

    // MARK: - Offering

    private func offer(_ release: GitHubRelease, userInitiated: Bool) {
        guard let version = release.version, let currentVersion else { return }
        let installable = release.archive != nil

        let alert = NSAlert()
        alert.messageText = "AI Session Radar \(version) is available"
        var text = "You have \(currentVersion)."
        if let notes = Self.excerpt(release.notes) { text += "\n\n" + notes }
        if !installable { text += "\n\nThis release has to be installed by hand." }
        alert.informativeText = text
        alert.addButton(withTitle: installable ? "Install and Relaunch" : "View Release")
        alert.addButton(withTitle: "Later")
        // Skipping only makes sense for the nag. Someone who asked has already decided to look.
        if !userInitiated { alert.addButton(withTitle: "Skip This Version") }

        // An accessory app is never active, and an alert from an inactive app opens behind
        // whatever the user is doing.
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installable { install(release, version: version) } else { NSWorkspace.shared.open(release.pageURL) }
        case .alertThirdButtonReturn:
            preferences.skippedUpdateVersion = release.tagName
        default:
            break
        }
    }

    private func install(_ release: GitHubRelease, version: AppVersion) {
        status = .installing
        Task { @MainActor in
            do {
                let installed = try await UpdateInstaller(session: session).install(release, version: version)
                UpdateInstaller.relaunch(at: installed)
            } catch {
                status = .available(release)
                Log.app.error("update install failed: \(error.localizedDescription, privacy: .public)")
                showError("AI Session Radar was not updated", error.localizedDescription, page: release.pageURL)
            }
        }
    }

    // MARK: - Alerts

    private func showUpToDate(_ version: AppVersion) {
        let alert = NSAlert()
        alert.messageText = "AI Session Radar is up to date"
        alert.informativeText = "Version \(version) is the latest release."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// With a release page to fall back on, the alert offers it — every failure the
    /// installer can report still leaves the manual route open.
    private func showError(_ title: String, _ message: String, page: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if page != nil {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let page {
            NSWorkspace.shared.open(page)
        }
    }

    /// Release notes are Markdown written for a web page. An alert shows plain text in a
    /// narrow column, so keep it to the first few hundred characters.
    static func excerpt(_ notes: String?, limit: Int = 400) -> String? {
        guard let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else {
            return nil
        }
        guard notes.count > limit else { return notes }
        let cut = notes.prefix(limit)
        let end = cut.lastIndex(where: { $0 == "\n" || $0 == " " }) ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
