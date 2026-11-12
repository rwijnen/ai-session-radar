// AI Session Radar: menu bar item plus the board window.
//
// Shows how many Claude sessions need you, are ready to review and are working,
// as coloured counts in the menu bar. The menu lists the sessions; clicking one
// brings its app to the front. "Open board" (or opening the app again from
// Spotlight or Finder) shows the board window. All data comes from `radar json`,
// so the logic lives in one place (the Python package) and the app only draws it.
// On first launch a welcome window checks Python, installs the Claude Code hooks and
// shows the settings; the in-app updater keeps the app current from GitHub Releases.
import AppKit
import Combine
import SwiftUI

final class RadarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = Store()
    lazy var board = BoardWindow(store: store)
    let alerts = Alerts()
    let setup = Setup()
    let config = RadarConfig()
    let preferences = Preferences()
    var updates: UpdateChecker!
    var settings: SettingsWindow!
    private var watchers: [Any] = []

    override init() {
        super.init()
        store.open = { [weak self] id in self?.background(["open", id]) }
        store.seen = { [weak self] id in self?.background(["seen", id]) }
        alerts.open = { [weak self] id in self?.background(["open", id]) }
        store.refreshPRs = { [weak self] in self?.refreshPRs() }
        store.reviewPR = { [weak self] id in self?.reviewPR(id) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        setup.prepare()
        updates = MainActor.assumeIsolated { UpdateChecker(preferences: preferences) }
        settings = SettingsWindow { [unowned self] welcome, close in
            AnyView(SettingsView(setup: setup, config: config, updates: updates, preferences: preferences, alerts: alerts,
                                 store: store, welcome: welcome, done: { [unowned self] in preferences.setupDone = true; close() }))
        }
        settings.onClose = { [weak self] in self?.windowClosed() }
        board.onClose = { [weak self] in self?.windowClosed() }
        NSApp.mainMenu = mainMenu()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        alerts.start()
        draw()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.refresh() }
        // Pull requests: from GitHub every 2 minutes (one GraphQL call through gh).
        refreshPRs()
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refreshPRs() }
        watchers.append(config.$prsEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPRs() }
        })
        watchers.append(config.$prRepos.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPRs() }
        })
        watchers.append(config.$prCheckouts.sink { [weak self] set in self?.store.prCheckoutsSet = set })
        MainActor.assumeIsolated { updates.start() }
        // The welcome window: on first launch, and whenever Python or the hooks are missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if !self.preferences.setupDone || !self.setup.ready { self.settings.show(welcome: true) }
        }
        if CommandLine.arguments.contains("--board") { board.show() }
    }

    /// Opening the app again (Spotlight, Finder, `open -a`) while it runs shows the board.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        board.show()
        return false
    }

    // MARK: data

    /// Runs the radar command line (the stable copy in ~/.claude/radar/lib, with the Python Setup found).
    @discardableResult
    func radar(_ args: [String]) -> Data? {
        let r = setup.radar(args)
        return r.status == 0 ? r.output : nil
    }

    /// The Dock icon only shows while one of the app's windows is open.
    func windowClosed() {
        DispatchQueue.main.async {
            let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func background(_ args: [String]) {
        DispatchQueue.global().async { self.radar(args); self.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let data = self.radar(["json"])
            var parsed: [Row] = [], counts: [String: Int] = [:], error: String? = nil
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsed = (json["sessions"] as? [[String: Any]] ?? []).compactMap(Row.init)
                counts = json["counts"] as? [String: Int] ?? [:]
            } else {
                error = self.setup.python == nil ? "Python 3 not found: open Settings to finish setup" : "radar did not answer (\(Setup.cli.path))"
            }
            DispatchQueue.main.async {
                if self.store.rows != parsed { self.store.rows = parsed }
                if self.store.counts != counts { self.store.counts = counts }
                if self.store.error != error { self.store.error = error }
                self.store.updated = Date()
                self.draw()
                // Skip a failed refresh: its empty list would make every session "arrive" again.
                if error == nil {
                    self.alerts.alert(self.alerts.arrivals(parsed), button: self.item.button, boardOpen: self.board.isOpen)
                    self.alerts.clear(parsed)
                }
            }
        }
    }

    func refreshPRs() {
        store.prsEnabled = config.prsEnabled
        guard config.prsEnabled else {
            store.prs = []; store.prError = nil; store.prFetched = nil
            DispatchQueue.global(qos: .utility).async { self.radar(["prs-json", "--refresh"]) }  // clears the cache: no PR badges
            draw()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            guard let data = self.radar(["prs-json", "--refresh"]),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.store.prError = self.setup.python == nil ? "Python 3 not found (see Settings)" : "radar prs-json did not answer"
                }
                return
            }
            let prs = (json["prs"] as? [[String: Any]] ?? []).compactMap(PR.init)
            let error = json["error"] as? String
            let watched = self.watchedRepos()
            let found = (json["checkouts"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let defaultPrompt = json["review_prompt_default"] as? String ?? ""
            DispatchQueue.main.async {
                if self.store.prs != prs { self.store.prs = prs }
                if self.store.prCheckoutsFound != found { self.store.prCheckoutsFound = found }
                if self.store.prReviewDefault != defaultPrompt { self.store.prReviewDefault = defaultPrompt }
                self.store.prError = error
                self.store.prWatched = watched
                self.store.prFetched = Date()
                self.draw()
                // A failed fetch keeps the last good list, so it never looks like new arrivals.
                if error == nil { self.alerts.alertPRs(self.alerts.prArrivals(prs), button: self.item.button, boardOpen: self.board.isOpen) }
            }
        }
    }

    func watchedRepos() -> [String] { config.prRepos }

    /// Review with Claude: `radar review` opens a new Desktop session in the PR's checkout with the
    /// review prompt typed in. The button is off when no checkout is known, so a failure is rare: a beep.
    func reviewPR(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.setup.radar(["review", id])
            if r.status != 0 {
                Log.app.error("radar review \(id, privacy: .public) failed with status \(r.status)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }

    // MARK: menu bar title

    func draw() {
        guard let button = item.button else { return }
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        for c in columns.prefix(3) {
            let n = store.counts[c.key] ?? 0
            guard n > 0 else { continue }
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(string: "●", attributes: [.foregroundColor: c.colour, .font: NSFont.systemFont(ofSize: 9)]))
            title.append(NSAttributedString(string: "\u{2009}\(n)", attributes: [.font: font]))
        }
        // Pull requests that wait on you: a PR symbol and the count.
        let prsForYou = store.prs.filter { $0.group == "you" }.count
        if prsForYou > 0 {
            title.append(NSAttributedString(string: "  "))
            if let img = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "pull requests") {
                img.isTemplate = true
                let a = NSTextAttachment()
                a.image = img
                a.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
                title.append(NSAttributedString(attachment: a))
            }
            title.append(NSAttributedString(string: "\u{2009}\(prsForYou)", attributes: [.font: font]))
        }
        let symbol = store.error != nil ? "exclamationmark.triangle" : "dot.radiowaves.left.and.right"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AI Session Radar")
        button.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.attributedTitle = title
        button.toolTip = store.error ?? (setup.ready ? "AI Session Radar" : "AI Session Radar: setup needed (open Settings)")
    }

    // MARK: menus

    func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(action("Settings…", #selector(openSettings), ","))
        appMenu.addItem(action("Check for Updates…", #selector(checkUpdates), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AI Session Radar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = store.rows
        if let error = store.error { menu.addItem(NSMenuItem(title: error, action: nil, keyEquivalent: "")) }
        if rows.isEmpty && store.error == nil { menu.addItem(NSMenuItem(title: "No Claude sessions running", action: nil, keyEquivalent: "")) }
        for c in columns {
            var group = rows.filter { $0.column == c.key }
            if c.key == "done" { group = group.filter { !$0.seen } }
            guard !group.isEmpty else { continue }
            if menu.items.count > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let sessions = group.filter { !$0.isAgent }.count, agents = group.count - sessions
            // Colour lives on the dot and the count badge; the text stays in system grey,
            // which keeps its contrast on the menu's see-through background.
            let headFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let head = NSMutableAttributedString(attachment: dotAttachment(badgeFill(c), font: headFont))
            head.append(NSAttributedString(string: " \(c.title)  ", attributes: [.font: headFont, .foregroundColor: NSColor.secondaryLabelColor]))
            head.append(NSAttributedString(attachment: pillAttachment("\(sessions)", fill: badgeFill(c), text: badgeText, font: headFont)))
            if agents > 0 {
                head.append(NSAttributedString(string: "  + \(agents) subagent\(agents == 1 ? "" : "s")",
                                               attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            header.attributedTitle = head
            menu.addItem(header)
            for r in group.prefix(c.key == "done" ? 6 : 30) {
                menu.addItem(r.isAgent ? agentEntry(r, c.colour, under: group.contains { $0.id == r.parentId }) : entry(r, c.colour))
            }
            if c.key == "done" && group.count > 6 {
                menu.addItem(NSMenuItem(title: "\(group.count - 6) more on the board", action: nil, keyEquivalent: ""))
            }
        }
        prSection(menu)
        menu.addItem(.separator())
        menu.addItem(action("Open board", #selector(openBoard), "b"))
        menu.addItem(action("Mark finished as seen", #selector(seenAll), ""))
        menu.addItem(.separator())
        if !setup.ready {
            let fix = action("Finish setup…", #selector(openWelcome), "")
            fix.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(fix)
        }
        menu.addItem(action("Settings…", #selector(openSettings), ","))
        menu.addItem(action("Check for Updates…", #selector(checkUpdates), ""))
        menu.addItem(.separator())
        menu.addItem(action("Quit AI Session Radar", #selector(quit), "q"))
    }

    func entry(_ r: Row, _ colour: NSColor) -> NSMenuItem {
        let mi = NSMenuItem(title: r.name, action: #selector(openSession(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = r.id
        let small = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString(string: String(r.name.prefix(70)), attributes: [.font: NSFont.menuFont(ofSize: 13)])
        // The app as a solid pill in its own colour, so the app is recognisable at a glance.
        text.append(NSAttributedString(string: "\n"))
        let style = appStyle(r.appKey)
        text.append(NSAttributedString(attachment: pillAttachment(r.app, fill: style.fill, text: style.text,
                                                                  font: NSFont.systemFont(ofSize: 10.5, weight: .semibold))))
        let place = r.folder + (r.branch.map { " · \($0)" } ?? "")
        let context = r.contextTokens.map { " · \(tokenCount($0))" } ?? ""
        text.append(NSAttributedString(string: "  \(place) · \(ago(r.waiting))\(context)", attributes: [
            .font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        if let d = r.detail, ["needs", "review"].contains(r.column) {
            text.append(NSAttributedString(string: "\n→ " + String(d.prefix(90)), attributes: [.font: small, .foregroundColor: NSColor.labelColor]))
        }
        mi.attributedTitle = text
        mi.toolTip = r.detail
        return mi
    }

    func agentEntry(_ r: Row, _ colour: NSColor, under: Bool) -> NSMenuItem {
        let mi = NSMenuItem(title: r.name, action: #selector(openSession(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = r.id
        mi.indentationLevel = 1
        let small = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString(string: "↳ ", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: String(r.name.prefix(60)), attributes: [.font: NSFont.menuFont(ofSize: 12)]))
        text.append(NSAttributedString(string: "\n   \(r.agentType)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        let rest = (r.background ? " · background" : "") + " · \(ago(r.waiting))" + (under ? "" : " · in \(r.parentName ?? "")")
        text.append(NSAttributedString(string: rest, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        mi.attributedTitle = text
        mi.toolTip = r.detail
        return mi
    }

    // MARK: pills and dots
    // Drawn as images so the colour sits on a solid shape. The drawing handler runs at draw
    // time, so the dynamic colours follow the menu's light or dark appearance.

    /// Count badges: the column colour, with Done darker in light mode so white text reads on it.
    func badgeFill(_ c: ColumnStyle) -> NSColor { c.key == "done" ? dynamic(0x6B6962, 0x8F8B82) : c.colour }
    /// White on the deeper light-mode fills, near-black on the lighter dark-mode ones.
    let badgeText = dynamic(0xFFFFFF, 0x1C1C1E)

    func pillAttachment(_ label: String, fill: NSColor, text: NSColor, font: NSFont) -> NSTextAttachment {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
        let size = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 5, h = ceil(font.capHeight + 7)
        let w = max(h, ceil(size.width) + pad * 2)
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            (label as NSString).draw(at: NSPoint(x: (w - size.width) / 2, y: (h - size.height) / 2), withAttributes: attrs)
            return true
        }
        let a = NSTextAttachment()
        a.image = image
        a.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
        return a
    }

    func dotAttachment(_ colour: NSColor, font: NSFont) -> NSTextAttachment {
        let d: CGFloat = 7
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let a = NSTextAttachment()
        a.image = image
        a.bounds = CGRect(x: 0, y: (font.capHeight - d) / 2, width: d, height: d)
        return a
    }

    func action(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        background(["open", id])
    }

    @objc func seenAll() { background(["seen", "all"]) }
    @objc func openPR(_ sender: NSMenuItem) { if let u = sender.representedObject as? String { openURL(u) } }

    /// The PRs that wait on you, with a line for the rest.
    func prSection(_ menu: NSMenu) {
        let mine = store.prs.filter { $0.group == "you" }
        let rest = store.prs.count - mine.count
        guard !store.prs.isEmpty else { return }
        menu.addItem(.separator())
        let headFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let style = prGroups[0]
        let head = NSMutableAttributedString(attachment: dotAttachment(style.colour, font: headFont))
        head.append(NSAttributedString(string: " Pull requests  ", attributes: [.font: headFont, .foregroundColor: NSColor.secondaryLabelColor]))
        if !mine.isEmpty {
            head.append(NSAttributedString(attachment: pillAttachment("\(mine.count)", fill: style.colour, text: badgeText, font: headFont)))
        }
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = head
        menu.addItem(header)
        let small = NSFont.systemFont(ofSize: 11)
        for pr in mine.prefix(8) {
            let mi = NSMenuItem(title: pr.title, action: #selector(openPR(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = pr.url
            let t = NSMutableAttributedString(string: String(pr.title.prefix(70)), attributes: [.font: NSFont.menuFont(ofSize: 13)])
            t.append(NSAttributedString(string: "\n\(pr.repoName) #\(pr.number) · \(pr.author) · ", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            t.append(NSAttributedString(string: pr.reason, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            mi.attributedTitle = t
            menu.addItem(mi)
        }
        if rest > 0 {
            let more = action("\(rest) more on the board", #selector(openPRBoard), "")
            menu.addItem(more)
        }
    }

    @objc func openPRBoard() {
        UserDefaults.standard.set(RadarView.prs.rawValue, forKey: "radarView")
        board.show()
    }

    @objc func openBoard() { board.show() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openSettings() { settings.show() }
    @objc func openWelcome() { settings.show(welcome: true) }
    @objc func checkUpdates() { MainActor.assumeIsolated { updates.checkNow() } }
}

let app = NSApplication.shared
let delegate = RadarApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
