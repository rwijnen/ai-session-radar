import AppKit
import Foundation

/// Downloads a release, proves it came from the same signer as the running copy, and swaps
/// it in place of the running bundle.
///
/// Every step that can refuse does so before the running copy is touched, and the swap
/// itself is a single `replaceItemAt` — so a failure anywhere leaves the old app exactly
/// as it was.
struct UpdateInstaller {
    enum Failure: LocalizedError {
        case notAnApp
        case noArchive
        case notWritable(URL)
        case unsignedRunningCopy
        case download(String)
        case unpack
        case signatureMismatch
        case versionMismatch(expected: AppVersion, found: String?)

        var errorDescription: String? {
            switch self {
            case .notAnApp:
                "AI Session Radar is not running from an app bundle, so there is nothing to replace."
            case .noArchive:
                "This release has no \(GitHubRelease.archiveName) to install from."
            case .notWritable(let folder):
                "AI Session Radar cannot write to \(folder.path)."
            case .unsignedRunningCopy:
                "This copy of AI Session Radar has no Apple signing identity, so there is no way to "
                    + "check that a download was built by the same person."
            case .download(let reason):
                "The download failed: \(reason)"
            case .unpack:
                "The downloaded archive did not contain AI Session Radar.app."
            case .signatureMismatch:
                "The download is not signed by the same developer as this copy of AI Session Radar, "
                    + "so it was not installed."
            case .versionMismatch(let expected, let found):
                "The download claims to be version \(found ?? "unknown"), not \(expected)."
            }
        }
    }

    /// Release archives are a few megabytes. Anything far beyond that is not what the
    /// release workflow produces, and is not worth spending the disk on to find out.
    private static let maximumArchiveSize = 100 * 1024 * 1024

    var session: URLSession = .shared

    /// Installs `release` over the running bundle and returns where it now lives. The
    /// caller relaunches; this never quits the app.
    func install(_ release: GitHubRelease, version: AppVersion) async throws -> URL {
        let running = Bundle.main.bundleURL
        guard AppBundle.isApp, let identifier = Bundle.main.bundleIdentifier else {
            throw Failure.notAnApp
        }
        guard let archive = release.archive, archive.size <= Self.maximumArchiveSize else {
            throw Failure.noArchive
        }
        let folder = running.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure.notWritable(folder)
        }
        // Checked before downloading, because without it nothing downloaded could pass.
        guard let team = CodeSignature.teamIdentifier(of: running) else {
            throw Failure.unsignedRunningCopy
        }

        // On the same volume as the app, so the final swap is a rename rather than a copy
        // that could be interrupted half-way.
        let workspace = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: running,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let zip = workspace.appendingPathComponent(GitHubRelease.archiveName)
        try await download(archive.downloadURL, to: zip)

        let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
        let candidate = try await Task.detached {
            try Self.unzip(zip, into: unpacked)
        }.value

        let valid = await Task.detached {
            CodeSignature.isValid(candidate, identifier: identifier, teamIdentifier: team)
        }.value
        guard valid else { throw Failure.signatureMismatch }

        // Read the plist directly: `Bundle(url:)` caches by path and could answer for a
        // bundle that used to be there.
        let plist = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist"))
        let found = plist?["CFBundleShortVersionString"] as? String
        guard let found, AppVersion(found) == version else {
            throw Failure.versionMismatch(expected: version, found: found)
        }

        Log.app.info("installing AI Session Radar \(version.description, privacy: .public) over \(running.path, privacy: .public)")
        let installed = try FileManager.default.replaceItemAt(running, withItemAt: candidate) ?? running
        // Launch Services keys its caches on the bundle; a fresh mtime makes it look again.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.path)
        return installed
    }

    /// Opens the app at `url` once this process has exited, then quits.
    ///
    /// The relaunch has to come from outside: a second copy started before this one quits
    /// would briefly put two copies in the menu bar, and one started after cannot be
    /// started by a process that no longer exists. A detached shell waiting on our PID
    /// bridges the gap.
    @MainActor
    static func relaunch(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "radar-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            url.path,
        ]
        do {
            try process.run()
        } catch {
            Log.app.error("could not schedule relaunch: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    // MARK: - Steps

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        do {
            let (file, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: file)
                throw Failure.download("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            try FileManager.default.moveItem(at: file, to: destination)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    /// `ditto` rather than a hand-rolled unzip: it is what produced the archive, and it
    /// restores the extended attributes a code signature depends on.
    private static func unzip(_ zip: URL, into folder: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        let app = folder.appendingPathComponent("AI Session Radar.app", isDirectory: true)
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        else { throw Failure.unpack }
        return app
    }
}
