// Alerts when a session moves into "Needs you" or "Ready to review": the menu bar icon
// jumps (and the Dock icon, while the board is open), and a notification is posted.
// Clicking the notification opens the session. Each can be switched off in the menu.
import AppKit
import UserNotifications

final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    /// Column per session from the previous refresh; nil until the first one, so the
    /// sessions already waiting when the app starts do not all fire at once.
    private var previous: [String: String]?
    private var previousPRs: [String: String]?
    var open: (String) -> Void = { _ in }

    // Settings, in the app's own defaults (local.claude-radar).
    private let defaults = UserDefaults.standard
    var bounce: Bool {
        get { defaults.object(forKey: "alertBounce") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alertBounce") }
    }
    var notify: Bool {
        get { defaults.object(forKey: "alertNotify") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alertNotify"); if newValue { authorise() } }
    }
    /// The Desktop app already notifies for its own sessions, so those are left out by default.
    var notifyDesktop: Bool {
        get { defaults.object(forKey: "alertNotifyDesktop") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "alertNotifyDesktop") }
    }

    var prAlerts: Bool {
        get { defaults.object(forKey: "alertPRs") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alertPRs") }
    }

    private var center: UNUserNotificationCenter? {
        // Notifications need a bundle; running the bare binary (no bundle id) would crash.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        center?.delegate = self
        if notify { authorise() }
    }

    private func authorise() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sessions (not subagents) that entered Needs you or Ready to review since the last refresh.
    func arrivals(_ rows: [Row]) -> [Row] {
        let sessions = rows.filter { !$0.isAgent }
        let now = Dictionary(sessions.map { ($0.id, $0.column) }, uniquingKeysWith: { a, _ in a })
        defer { previous = now }
        guard let before = previous else { return [] }
        return sessions.filter { ["needs", "review"].contains($0.column) && before[$0.id] != $0.column }
    }

    func alert(_ arrived: [Row], button: NSStatusBarButton?, boardOpen: Bool) {
        guard !arrived.isEmpty else { return }
        if bounce {
            if let button { jump(button) }
            if boardOpen { NSApp.requestUserAttention(.informationalRequest) }
        }
        if notify {
            for r in arrived where r.appKey != "desktop" || notifyDesktop { post(r) }
        }
    }

    /// PRs that started waiting on you, and your own PRs that became ready to merge.
    func prArrivals(_ prs: [PR]) -> [PR] {
        let now = Dictionary(prs.map { ($0.id, $0.group + "|" + $0.reason) }, uniquingKeysWith: { a, _ in a })
        defer { previousPRs = now }
        guard let before = previousPRs else { return [] }
        return prs.filter { pr in
            let was = before[pr.id]
            if pr.group == "you" { return was != now[pr.id] }        // new, or a new reason (another check failed)
            if pr.group == "ready" && pr.mine { return was?.hasPrefix("ready|") != true }
            return false
        }
    }

    func alertPRs(_ arrived: [PR], button: NSStatusBarButton?, boardOpen: Bool) {
        guard prAlerts, !arrived.isEmpty else { return }
        if bounce {
            if let button { jump(button) }
            if boardOpen { NSApp.requestUserAttention(.informationalRequest) }
        }
        guard notify, let center else { return }
        for pr in arrived {
            let content = UNMutableNotificationContent()
            content.title = (pr.group == "ready" ? "Ready to merge: " : "PR: ") + pr.title
            content.subtitle = "\(pr.repoName) #\(pr.number) · \(pr.author)"
            content.body = pr.reason.prefix(1).uppercased() + pr.reason.dropFirst()
                + (pr.checks.failing.isEmpty ? "" : ": " + pr.checks.failing.joined(separator: ", "))
            content.userInfo = ["url": pr.url]
            if pr.group == "you" { content.sound = .default }
            center.add(UNNotificationRequest(identifier: "pr:" + pr.id, content: content, trigger: nil))
        }
    }

    /// Three hops, each lower than the last, played twice.
    private func jump(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, 9, 0, 5, 0, 2, 0]
        hop.keyTimes = [0, 0.16, 0.34, 0.5, 0.66, 0.8, 1]
        hop.timingFunctions = (0..<6).map { CAMediaTimingFunction(name: $0 % 2 == 0 ? .easeOut : .easeIn) }
        hop.duration = 1.0
        hop.repeatCount = 2
        layer.add(hop, forKey: "jump")
    }

    private func post(_ r: Row) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        let needs = r.column == "needs"
        content.title = (needs ? "Needs you: " : "Ready to review: ") + r.name
        content.subtitle = [r.app, r.folder].filter { !$0.isEmpty }.joined(separator: " · ")
        if let d = r.detail {
            let label = r.kind.flatMap { kindLabels[$0] }.map { "\($0): " } ?? ""
            content.body = label + d
        }
        content.userInfo = ["session": r.id]
        if needs { content.sound = .default }
        // One notification per session: a newer one replaces the older.
        center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: nil))
    }

    /// Clears a session's notification once it no longer waits (answered, opened or seen).
    func clear(_ rows: [Row]) {
        let waiting = Set(rows.filter { ["needs", "review"].contains($0.column) }.map(\.id))
        center?.getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { !$0.hasPrefix("pr:") && !waiting.contains($0) }
            if !stale.isEmpty { self.center?.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let id = info["session"] as? String {
            DispatchQueue.main.async { self.open(id) }
        } else if let url = info["url"] as? String {
            DispatchQueue.main.async { openURL(url) }
        }
        done()
    }
}
