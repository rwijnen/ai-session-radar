import Foundation

/// A dotted version number — `1.2.3`, compared numerically so that `1.10` is newer than
/// `1.9`. A leading `v` is ignored, as is anything after the numbers (`1.2.0-beta`), since
/// `releases/latest` never returns a pre-release anyway.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let numeric = text.prefix { $0.isNumber || $0 == "." }
        let components = numeric.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !components.isEmpty, components.allSatisfy({ $0 != nil }) else { return nil }
        self.components = components.compactMap { $0 }
    }

    /// Missing components count as zero, so `1.2` and `1.2.0` are the same version.
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

/// The parts of a GitHub release that matter here, from
/// `GET /repos/{owner}/{repo}/releases/latest`.
struct GitHubRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        var name: String
        var size: Int
        var downloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var name: String?
    var notes: String?
    var pageURL: URL
    var assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case notes = "body"
        case pageURL = "html_url"
        case assets
    }

    /// The release workflow publishes the app bundle zipped under exactly this name.
    static let archiveName = "AI-Session-Radar.zip"

    var version: AppVersion? { AppVersion(tagName) }

    /// The zipped app, if this release has one. A release without it can still be
    /// announced, but has to be installed by hand.
    var archive: Asset? { assets.first { $0.name == Self.archiveName } }

    static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
