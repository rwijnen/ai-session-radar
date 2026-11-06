import AppKit
import Foundation

/// Everything the app needs from the Mac it runs on: a working Python 3, its own copy of the
/// radar package in a stable place, the Claude Code hooks, and (for pull requests) the GitHub CLI.
///
/// The package ships inside the app (Contents/Resources/radar) and is copied to
/// ~/.claude/radar/lib whenever the app's build changes. The hooks point at that copy, so
/// moving the app or installing an update never leaves Claude Code calling a missing file.
final class Setup: ObservableObject {
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/radar")
    static let libDir = stateDir.appendingPathComponent("lib")
    static var cli: URL { libDir.appendingPathComponent("bin/radar") }

    struct Hooks: Equatable { var installed: [String] = []; var missing: [String] = []; var current = false }

    @Published private(set) var python: String?
    @Published private(set) var hooks = Hooks()
    @Published private(set) var gh: String?            // nil: not found; "" found but not signed in; login otherwise
    @Published private(set) var ghChecked = false
    @Published private(set) var message: String?

    var ready: Bool { python != nil && hooks.current }

    /// On launch: copy the package when the build changed, find Python, read the hook state.
    func prepare() {
        syncLibrary()
        python = Self.findPython()
        refresh()
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let hooks = self.readHooks()
            let gh = Self.ghLogin()
            DispatchQueue.main.async {
                self.hooks = hooks
                self.gh = gh
                self.ghChecked = true
            }
        }
    }

    // MARK: Python

    /// /usr/bin/python3 only counts when the Command Line Tools are installed: without them it is
    /// a stub that opens an install dialog every time something runs it, hooks included.
    static func findPython() -> String? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        if run("/usr/bin/xcode-select", ["-p"]).status == 0 { candidates.insert("/usr/bin/python3", at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0)
            && run($0, ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"]).status == 0 }
    }

    // MARK: Library

    private func syncLibrary() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("radar"),
              FileManager.default.fileExists(atPath: source.path) else { return }
        let stamp = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
        let stampFile = Self.libDir.appendingPathComponent("BUILD")
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp { return }
        let fm = FileManager.default
        let staging = Self.stateDir.appendingPathComponent("lib.new")
        try? fm.removeItem(at: staging)
        do {
            try fm.createDirectory(at: Self.stateDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            try stamp.write(to: staging.appendingPathComponent("BUILD"), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: Self.libDir.path) {
                _ = try fm.replaceItemAt(Self.libDir, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: Self.libDir)
            }
            Log.app.info("radar package copied to \(Self.libDir.path, privacy: .public) (build \(stamp, privacy: .public))")
        } catch {
            Log.app.error("could not copy the radar package: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Hooks

    private func readHooks() -> Hooks {
        guard python != nil, let out = radar(["hooks-status"]).output,
              let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else { return Hooks() }
        return Hooks(installed: json["installed"] as? [String] ?? [], missing: json["missing"] as? [String] ?? [],
                     current: json["current"] as? Bool ?? false)
    }

    /// Adds the hooks (with a backup of settings.json), or takes them out again.
    func setHooks(_ install: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.radar([install ? "install" : "uninstall"])
            let text = String(data: result.output ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.message = result.status == 0 ? text : "That did not work: \(text ?? "no output")"
                self.refresh()
            }
        }
    }

    // MARK: GitHub CLI

    private static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func ghLogin() -> String? {
        guard let gh = ghPath() else { return nil }
        let r = run(gh, ["api", "user", "--jq", ".login"])
        guard r.status == 0, let data = r.output else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Running

    /// Runs the radar command line with the Python found here, from the stable copy.
    @discardableResult
    func radar(_ args: [String]) -> (status: Int32, output: Data?) {
        guard let python else { return (127, nil) }
        return Self.run(python, [Self.cli.path] + args, env: ["RADAR_PYTHON": python])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:]) -> (status: Int32, output: Data?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env.merge(extra) { _, new in new }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (127, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}
