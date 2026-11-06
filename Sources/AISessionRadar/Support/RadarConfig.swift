import Foundation

/// Settings the Python side reads too, in ~/.claude/radar/config.json. Writes merge into the
/// file, so keys this app does not know about are kept.
final class RadarConfig: ObservableObject {
    static let url = Setup.stateDir.appendingPathComponent("config.json")

    @Published var prsEnabled: Bool { didSet { save("prs_enabled", prsEnabled) } }
    @Published var prRepos: [String] { didSet { save("pr_repos", prRepos) } }
    @Published var prOthers: Bool { didSet { save("pr_others", prOthers) } }
    @Published var prStaleDays: Int { didSet { save("pr_stale_days", prStaleDays) } }

    init() {
        let stored = Self.read()
        prsEnabled = stored["prs_enabled"] as? Bool ?? true
        prRepos = stored["pr_repos"] as? [String] ?? []
        prOthers = stored["pr_others"] as? Bool ?? true
        prStaleDays = stored["pr_stale_days"] as? Int ?? 14
    }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func save(_ key: String, _ value: Any) {
        var stored = Self.read()
        stored[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
