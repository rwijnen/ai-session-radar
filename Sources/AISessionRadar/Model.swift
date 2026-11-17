// Data and colours shared by the menu bar menu and the board window.
import AppKit
import SwiftUI

struct Row: Identifiable, Equatable {
    let id: String, name: String, app: String, appKey: String, folder: String, branch: String?, cwd: String
    let column: String, kind: String?, detail: String?, files: [String], lastPrompt: String?
    let waiting: Int, seen: Bool, tracked: Bool
    // Subagents: a Working row of their own, placed after their parent.
    let isAgent: Bool, agentType: String, parentId: String?, parentName: String?, background: Bool, tools: Int
    // Context of the latest reply (tokens), its model, and the window only where the model id states it.
    let contextTokens: Int?, model: String?, contextWindow: Int?
    // Timeline: state changes [(state, since)] and finished subagents (the last week), and
    // whether the session has been closed (then only the timeline shows it).
    let history: [(state: String, at: Double)], agentHistory: [AgentSpan], closed: Bool
    // The open pull request of the session's branch, if there is one.
    let pr: PRLink?

    static func == (a: Row, b: Row) -> Bool {
        a.id == b.id && a.column == b.column && a.detail == b.detail && a.waiting / 5 == b.waiting / 5
            && a.name == b.name && a.seen == b.seen && a.tools == b.tools && a.contextTokens == b.contextTokens
            && a.history.count == b.history.count && a.agentHistory.count == b.agentHistory.count
            && a.pr == b.pr
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let column = d["column"] as? String else { return nil }
        self.id = id; self.column = column
        closed = d["state"] as? String == "ended"
        name = d["name"] as? String ?? id
        app = d["app"] as? String ?? ""
        appKey = d["app_key"] as? String ?? "terminal"
        folder = d["folder"] as? String ?? ""
        branch = d["branch"] as? String
        cwd = d["cwd"] as? String ?? ""
        kind = d["kind"] as? String
        detail = d["detail"] as? String
        files = d["files"] as? [String] ?? []
        lastPrompt = d["last_prompt"] as? String
        waiting = d["waiting_s"] as? Int ?? 0
        seen = d["seen"] as? Bool ?? false
        tracked = d["tracked"] as? Bool ?? false
        isAgent = d["is_agent"] as? Bool ?? false
        agentType = d["agent_type"] as? String ?? "agent"
        parentId = d["parent_id"] as? String
        parentName = d["parent_name"] as? String
        background = d["background"] as? Bool ?? false
        tools = d["tools"] as? Int ?? 0
        contextTokens = d["context_tokens"] as? Int
        model = d["model"] as? String
        contextWindow = d["context_window"] as? Int
        history = (d["history"] as? [[Any]] ?? []).compactMap { h in
            guard h.count >= 2, let s = h[0] as? String, let at = (h[1] as? NSNumber)?.doubleValue else { return nil }
            return (s, at)
        }
        pr = (d["pr"] as? [String: Any]).flatMap(PRLink.init)
        agentHistory = (d["agent_history"] as? [[Any]] ?? []).compactMap { a in
            guard a.count >= 5, let start = (a[2] as? NSNumber)?.doubleValue, let end = (a[3] as? NSNumber)?.doubleValue
            else { return nil }
            return AgentSpan(type: a[0] as? String ?? "agent", description: a[1] as? String, start: start, end: end,
                             background: a[4] as? Bool ?? false)
        }
    }

    /// "331k context", plus "· 33%" where the window is known.
    var contextLabel: String? {
        guard let t = contextTokens else { return nil }
        let pct = contextWindow.map { " · \(Int((Double(t) / Double($0) * 100).rounded()))%" } ?? ""
        return "\(tokenCount(t)) context\(pct)"
    }
}

/// 950 → "950", 12_300 → "12k", 331_678 → "332k", 1_200_000 → "1.2M".
func tokenCount(_ n: Int) -> String {
    if n < 1000 { return "\(n)" }
    if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
    return String(format: "%.1fM", Double(n) / 1_000_000)
}

/// What the board and the menu draw from; refreshed by the app every 2.5 s.
final class Store: ObservableObject {
    @Published var rows: [Row] = []
    /// Sessions closed in the last week: only the timeline draws them.
    @Published var closed: [Row] = []
    @Published var counts: [String: Int] = [:]
    @Published var error: String?
    @Published var updated: Date?
    // Pull requests, refreshed every 2 minutes through `radar prs-json`.
    @Published var prs: [PR] = []
    @Published var prsEnabled = true
    @Published var prError: String?
    @Published var prFetched: Date?
    @Published var prWatched: [String] = []
    // Review with Claude: checkouts found from sessions (owner/name → folder, from `radar prs-json`),
    // the ones set in Settings (mirrored from RadarConfig), and the built-in prompt.
    @Published var prCheckoutsFound: [String: String] = [:]
    @Published var prCheckoutsSet: [String: String] = [:]
    @Published var prReviewDefault = ""
    var open: (String) -> Void = { _ in }
    var seen: (String) -> Void = { _ in }
    var refreshPRs: () -> Void = {}
    var reviewPR: (String) -> Void = { _ in }

    func checkout(_ repo: String) -> ReviewCheckout { reviewCheckout(repo, set: prCheckoutsSet, found: prCheckoutsFound) }
}

func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func make(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light)
    }
}

struct ColumnStyle { let key: String, title: String, colour: NSColor }

/// Column colours carry the state: orange needs you, purple review, blue working, grey done.
let columns: [ColumnStyle] = [
    ColumnStyle(key: "needs", title: "Needs you", colour: dynamic(0xD9620B, 0xFF8A3D)),
    ColumnStyle(key: "review", title: "Ready to review", colour: dynamic(0x7B55D6, 0xA98BFF)),
    ColumnStyle(key: "working", title: "Working", colour: dynamic(0x1F78C8, 0x5AA9EF)),
    ColumnStyle(key: "done", title: "Done", colour: dynamic(0x8A877F, 0x8F8B82)),
]

/// `fill` paints a pill (with `text` on it), deep in both modes so white text keeps its contrast; `ink` is the same hue as text on a card,
/// darker in light mode so yellow and green stay readable.
struct AppStyle { let fill: NSColor, text: NSColor, ink: NSColor, symbol: String }

/// App colours stay clear of the column hues: magenta, green, yellow, slate. Each has its own icon too.
func appStyle(_ key: String) -> AppStyle {
    switch key {
    case "desktop": return AppStyle(fill: dynamic(0xC13584, 0xB8307C), text: .white, ink: dynamic(0xA82C72, 0xED7FB8), symbol: "sparkles")
    case "vscode": return AppStyle(fill: dynamic(0x138A6E, 0x11806A), text: .white, ink: dynamic(0x0E7A60, 0x4CCAA3), symbol: "chevron.left.forwardslash.chevron.right")
    case "ghostty": return AppStyle(fill: dynamic(0xD4A20B, 0xE8B923), text: NSColor(white: 0.12, alpha: 1), ink: dynamic(0x8A6400, 0xEBC24A), symbol: "terminal")
    default: return AppStyle(fill: dynamic(0x5E6773, 0x5E6773), text: .white, ink: dynamic(0x55606C, 0xA6AEB8), symbol: "apple.terminal")
    }
}

struct AgentSpan: Hashable { let type: String, description: String?, start: Double, end: Double?, background: Bool }

/// Colour of a session state (hook state names) on the timeline and in the graph.
func stateColour(_ state: String) -> NSColor {
    switch state {
    case "needs_you", "needs": return columns[0].colour
    case "review": return columns[1].colour
    case "working": return columns[2].colour
    default: return columns[3].colour
    }
}

/// The project a session belongs to, for grouping in the graph: its folder name.
func projectName(_ row: Row) -> String { row.folder.isEmpty ? "Other" : row.folder }

func ago(_ s: Int) -> String {
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
    return "\(s / 86400)d"
}

// MARK: - Pull requests

struct PRChecks: Equatable {
    let passed: Int, failed: Int, running: Int, skipped: Int, failing: [String]
    init(_ d: [String: Any]?) {
        passed = d?["passed"] as? Int ?? 0; failed = d?["failed"] as? Int ?? 0
        running = d?["running"] as? Int ?? 0; skipped = d?["skipped"] as? Int ?? 0
        failing = d?["failing"] as? [String] ?? []
    }
}

/// The vcrm-sf:pr-review comment: its verdict, the commit it reviewed, and GitHub's HTML of it.
struct AIReview: Equatable {
    let verdict: String, sha: String, current: Bool, url: String?, at: Double, html: String
    init?(_ d: [String: Any]?) {
        guard let d, let verdict = d["verdict"] as? String else { return nil }
        self.verdict = verdict
        sha = d["sha"] as? String ?? ""
        current = d["current"] as? Bool ?? false
        url = d["url"] as? String
        at = (d["at"] as? NSNumber)?.doubleValue ?? 0
        html = d["html"] as? String ?? ""
    }
    var label: String {
        ["APPROVE": "approve", "REQUEST_CHANGES": "changes needed", "COMMENT": "comments"][verdict] ?? verdict.lowercased()
    }
}

struct PR: Identifiable, Equatable {
    let id: String, repo: String, repoName: String, number: Int, title: String, url: String
    let jira: String?, author: String, mine: Bool, draft: Bool, base: String, head: String
    let createdAt: Double, updatedAt: Double, additions: Int, deletions: Int, files: Int, comments: Int
    let mergeable: String?, review: String?, requested: [String], requestedMe: Bool
    let checks: PRChecks, ai: AIReview?, group: String, reason: String

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let number = d["number"] as? Int else { return nil }
        self.id = id; self.number = number
        repo = d["repo"] as? String ?? ""
        repoName = d["repo_name"] as? String ?? repo
        title = d["title"] as? String ?? ""
        url = d["url"] as? String ?? ""
        jira = d["jira"] as? String
        author = d["author"] as? String ?? ""
        mine = d["mine"] as? Bool ?? false
        draft = d["draft"] as? Bool ?? false
        base = d["base"] as? String ?? ""
        head = d["head"] as? String ?? ""
        createdAt = (d["created_at"] as? NSNumber)?.doubleValue ?? 0
        updatedAt = (d["updated_at"] as? NSNumber)?.doubleValue ?? 0
        additions = d["additions"] as? Int ?? 0
        deletions = d["deletions"] as? Int ?? 0
        files = d["files"] as? Int ?? 0
        comments = d["comments"] as? Int ?? 0
        mergeable = d["mergeable"] as? String
        review = d["review"] as? String
        requested = d["requested"] as? [String] ?? []
        requestedMe = d["requested_me"] as? Bool ?? false
        checks = PRChecks(d["checks"] as? [String: Any])
        ai = AIReview(d["ai_review"] as? [String: Any])
        group = d["group"] as? String ?? "others"
        reason = d["reason"] as? String ?? ""
    }
}

/// The slim PR a session card carries (its branch's PR).
struct PRLink: Equatable {
    let id: String, number: Int, url: String, group: String, reason: String, checks: PRChecks, aiVerdict: String?
    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let number = d["number"] as? Int else { return nil }
        self.id = id; self.number = number
        url = d["url"] as? String ?? ""
        group = d["group"] as? String ?? "others"
        reason = d["reason"] as? String ?? ""
        checks = PRChecks(d["checks"] as? [String: Any])
        aiVerdict = d["ai_verdict"] as? String
    }
}

/// Where a Review with Claude session for a repo opens: the folder set in Settings, else the one
/// found from sessions. Usable only when the folder exists.
struct ReviewCheckout: Equatable {
    let folder: String?, fromSetting: Bool, exists: Bool
    var usable: Bool { folder != nil && exists }
}

func reviewCheckout(_ repo: String, set: [String: String], found: [String: String],
                    isFolder: (String) -> Bool = isDirectory) -> ReviewCheckout {
    let key = repo.lowercased()
    if let f = set.first(where: { $0.key.lowercased() == key && !$0.value.isEmpty })?.value {
        return ReviewCheckout(folder: f, fromSetting: true, exists: isFolder(f))
    }
    if let f = found.first(where: { $0.key.lowercased() == key })?.value {
        return ReviewCheckout(folder: f, fromSetting: false, exists: isFolder(f))
    }
    return ReviewCheckout(folder: nil, fromSetting: false, exists: false)
}

func isDirectory(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
}

/// "/Users/me/Repositories/app" → "~/Repositories/app".
func abbreviatedPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

struct PRGroupStyle { let key: String, title: String, colour: NSColor }

/// Grouped by who has to act; the colours follow the session columns, plus green for ready.
let prGroups: [PRGroupStyle] = [
    PRGroupStyle(key: "you", title: "Waits on you", colour: columns[0].colour),
    PRGroupStyle(key: "others", title: "Waits on others", colour: columns[2].colour),
    PRGroupStyle(key: "ready", title: "Ready to merge", colour: dynamic(0x1E7F4A, 0x4CC27A)),
    PRGroupStyle(key: "stale", title: "Stale", colour: columns[3].colour),
]
func prColour(_ group: String) -> NSColor { prGroups.first { $0.key == group }?.colour ?? columns[3].colour }

let failColour = dynamic(0xC4302B, 0xF06A63)
let passColour = dynamic(0x1E7F4A, 0x4CC27A)

func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
