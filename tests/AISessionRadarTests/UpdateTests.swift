import Foundation
import Testing

@testable import AISessionRadar

@Suite("Version comparison")
struct AppVersionTests {
    @Test("tags parse with or without a leading v", arguments: ["1.2.3", "v1.2.3", "V1.2.3", " 1.2.3 "])
    func parsesTags(_ tag: String) throws {
        #expect(try #require(AppVersion(tag)).components == [1, 2, 3])
    }

    @Test("a pre-release suffix is ignored")
    func ignoresSuffix() throws {
        #expect(try #require(AppVersion("v2.0.0-beta.1")).components == [2, 0, 0])
    }

    @Test("non-versions are rejected", arguments: ["", "v", "latest", "1..2", "1.2.", "x1.2"])
    func rejectsNonVersions(_ tag: String) {
        #expect(AppVersion(tag) == nil)
    }

    @Test("components compare as numbers, not text")
    func numericOrder() throws {
        #expect(try #require(AppVersion("1.10")) > #require(AppVersion("1.9")))
        #expect(try #require(AppVersion("2.0")) > #require(AppVersion("1.99.99")))
    }

    @Test("missing components count as zero")
    func paddedEquality() throws {
        #expect(try #require(AppVersion("1.2")) == #require(AppVersion("1.2.0")))
        #expect(try #require(AppVersion("1.2.1")) > #require(AppVersion("1.2")))
    }
}

/// JSON below is shaped like a real `GET /repos/{owner}/{repo}/releases/latest`
/// response, trimmed to the fields the app reads plus a few it must ignore.
@Suite("Release decoding")
struct GitHubReleaseTests {
    private let payload = Data("""
    {
      "url": "https://api.github.com/repos/rwijnen/ai-session-radar/releases/1",
      "html_url": "https://github.com/rwijnen/ai-session-radar/releases/tag/v1.1.0",
      "tag_name": "v1.1.0",
      "name": "AI Session Radar 1.1.0",
      "draft": false,
      "prerelease": false,
      "body": "## What's Changed\\n* Liquid Glass",
      "assets": [
        {
          "name": "AI-Session-Radar.zip",
          "size": 2345678,
          "content_type": "application/zip",
          "browser_download_url": "https://github.com/rwijnen/ai-session-radar/releases/download/v1.1.0/AI-Session-Radar.zip"
        },
        {
          "name": "checksums.txt",
          "size": 120,
          "browser_download_url": "https://github.com/rwijnen/ai-session-radar/releases/download/v1.1.0/checksums.txt"
        }
      ]
    }
    """.utf8)

    @Test("a release decodes with its version, page and archive")
    func decodes() throws {
        let release = try GitHubRelease.decode(payload)
        #expect(release.tagName == "v1.1.0")
        #expect(release.version?.components == [1, 1, 0])
        #expect(release.pageURL.absoluteString == "https://github.com/rwijnen/ai-session-radar/releases/tag/v1.1.0")
        #expect(release.notes == "## What's Changed\n* Liquid Glass")
        let archive = try #require(release.archive)
        #expect(archive.size == 2_345_678)
        #expect(archive.downloadURL.lastPathComponent == "AI-Session-Radar.zip")
    }

    @Test("a release without AI-Session-Radar.zip has no archive, so it is offered for manual install")
    func noArchive() throws {
        let json = """
        {"tag_name": "v1.1.0", "html_url": "https://github.com/rwijnen/ai-session-radar/releases/tag/v1.1.0",
         "body": null, "assets": []}
        """
        let release = try GitHubRelease.decode(Data(json.utf8))
        #expect(release.archive == nil)
        #expect(release.notes == nil)
    }

    @Test("long release notes are cut at a word boundary")
    @MainActor
    func excerpt() throws {
        let notes = String(repeating: "word ", count: 200)
        let excerpt = try #require(UpdateChecker.excerpt(notes, limit: 42))
        #expect(excerpt.hasSuffix("word…"))
        #expect(excerpt.count <= 43)
        #expect(UpdateChecker.excerpt("  short  ") == "short")
        #expect(UpdateChecker.excerpt("\n \n") == nil)
    }
}
