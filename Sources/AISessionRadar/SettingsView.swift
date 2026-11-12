// Settings, and the welcome window on first launch (the same view with a greeting on top).
// Setup: Python, the Claude Code hooks, the GitHub CLI. Features: pull requests (with the local
// checkouts and the prompt for Review with Claude) and alerts.
// Updates: the in-app updater. Every feature can be switched off here.
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var setup: Setup
    @ObservedObject var config: RadarConfig
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var preferences: Preferences
    let alerts: Alerts
    @ObservedObject var store: Store
    var welcome = false
    var done: () -> Void = {}

    @State private var bounce = true
    @State private var notify = true
    @State private var notifyDesktop = false
    @State private var prAlerts = true
    @State private var login = LaunchAtLogin.isEnabled
    @State private var newRepo = ""
    @State private var prompt = ""

    var body: some View {
        Form {
            if welcome {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to AI Session Radar").font(.title2.weight(.semibold))
                        Text("It shows every Claude Code session on this Mac (Desktop, VS Code and the terminal) by who is waiting on whom, and your open pull requests. To see your sessions it adds a few hooks to Claude Code's settings. Everything stays on this Mac; only the pull requests are read from GitHub, through your own GitHub CLI.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Setup") {
                row(ok: setup.python != nil, title: "Python 3",
                    detail: setup.python ?? "Not found. Install Apple's Command Line Tools: run xcode-select --install in Terminal, then reopen this window.")
                HStack {
                    row(ok: setup.hooks.current, title: "Claude Code hooks", detail: hooksText)
                    Spacer()
                    if setup.hooks.installed.isEmpty {
                        Button("Install hooks") { setup.setHooks(true) }.buttonStyle(.borderedProminent).disabled(setup.python == nil)
                    } else {
                        if !setup.hooks.current { Button("Repair") { setup.setHooks(true) }.buttonStyle(.borderedProminent) }
                        Button("Remove") { setup.setHooks(false) }
                    }
                }
                if let m = setup.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                row(ok: setup.gh?.isEmpty == false, optional: true, title: "GitHub CLI (for pull requests)", detail: ghText)
                Toggle("Open at login", isOn: $login)
                    .onChange(of: login) { _, on in login = LaunchAtLogin.set(on) }
                    .disabled(!LaunchAtLogin.isAvailable)
            }

            Section("Pull requests") {
                Toggle("Show pull requests", isOn: $config.prsEnabled)
                if config.prsEnabled {
                    Toggle("Also others' PRs in watched repos (not only PRs that involve you)", isOn: $config.prOthers)
                    Stepper("Stale after \(config.prStaleDays) days without activity", value: $config.prStaleDays, in: 1...90)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Watched repositories").font(.system(size: 12, weight: .medium))
                        ForEach(config.prRepos, id: \.self) { repo in
                            HStack {
                                Text(repo).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button { config.prRepos.removeAll { $0 == repo } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Repository", text: $newRepo, prompt: Text("owner/repo")).labelsHidden()
                                .textFieldStyle(.roundedBorder).onSubmit(addRepo)
                            Button("Add", action: addRepo).disabled(!validRepo)
                        }
                        Text("PRs that involve you (author, reviewer, assignee, mention) always show, from any repository.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    reviewSettings
                }
            }

            Section("Alerts when a session needs you or is ready to review") {
                Toggle("Jump the menu bar icon", isOn: $bounce).onChange(of: bounce) { _, v in alerts.bounce = v }
                Toggle("Send a notification", isOn: $notify).onChange(of: notify) { _, v in alerts.notify = v }
                Toggle("Also for Desktop sessions (the Desktop app already notifies)", isOn: $notifyDesktop)
                    .onChange(of: notifyDesktop) { _, v in alerts.notifyDesktop = v }.disabled(!notify)
                Toggle("Also for pull requests", isOn: $prAlerts).onChange(of: prAlerts) { _, v in alerts.prAlerts = v }
                    .disabled(!config.prsEnabled)
            }

            Section("Updates") { UpdateSection(updates: updates, preferences: preferences) }

            if welcome {
                HStack {
                    Spacer()
                    Button(setup.ready ? "Done" : "Later") { done() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: welcome ? 640 : 560)
        .onAppear {
            bounce = alerts.bounce; notify = alerts.notify; notifyDesktop = alerts.notifyDesktop; prAlerts = alerts.prAlerts
            login = LaunchAtLogin.isEnabled
            prompt = config.prReviewPrompt.isEmpty ? store.prReviewDefault : config.prReviewPrompt
            setup.refresh()
        }
        // The built-in prompt comes with the pull requests; it may arrive after the window opened.
        .onChange(of: store.prReviewDefault) { _, text in if config.prReviewPrompt.isEmpty { prompt = text } }
    }

    // MARK: Review with Claude

    @ViewBuilder private var reviewSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Review with Claude").font(.system(size: 12, weight: .medium))
            Text("A PR that waits on your review gets a Review with Claude button. It opens a new Claude Code Desktop session in the repository's local checkout with the prompt below typed in; press Return there to start it. The radar never starts one by itself.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(reviewRepos, id: \.self) { checkoutRow($0) }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Review prompt").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Reset to Default") { prompt = store.prReviewDefault }
                    .controlSize(.small).disabled(config.prReviewPrompt.isEmpty)
            }
            TextEditor(text: $prompt)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 190)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
                .onChange(of: prompt) { _, text in
                    // Stored only when it differs from the built-in prompt, so a later release's prompt still arrives.
                    let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let custom = blank || text == store.prReviewDefault ? "" : text
                    if config.prReviewPrompt != custom { config.prReviewPrompt = custom }
                }
            Text("Placeholders: {url} {repo} {number} {title} {head} {base}. Empty uses the built-in prompt.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Watched repos, repos with open PRs, and repos with a checkout set here.
    private var reviewRepos: [String] {
        var seen = Set<String>(), out: [String] = []
        for r in config.prRepos + store.prs.map(\.repo) + config.prCheckouts.keys.sorted() where seen.insert(r.lowercased()).inserted {
            out.append(r)
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    private func checkoutRow(_ repo: String) -> some View {
        let c = store.checkout(repo)
        let text: String = {
            guard let folder = c.folder else { return "No checkout found: choose its folder, or run a Claude session in it once" }
            let path = abbreviatedPath(folder)
            if !c.exists { return "\(path) · folder not found" }
            return c.fromSetting ? "\(path) · set here" : "\(path) · found from your Claude sessions"
        }()
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repo).font(.system(size: 12, design: .monospaced))
                Text(text).font(.system(size: 11)).foregroundStyle(c.usable ? Color.secondary : Color.orange)
                    .lineLimit(1).truncationMode(.middle).help(c.folder ?? "")
            }
            Spacer()
            Button("Choose…") { chooseCheckout(repo, current: c.folder) }.controlSize(.small)
            if c.fromSetting {
                Button("Reset") { config.prCheckouts = config.prCheckouts.filter { $0.key.lowercased() != repo.lowercased() } }
                    .controlSize(.small).help("Use the checkout found from your Claude sessions again")
            }
        }
    }

    private func chooseCheckout(_ repo: String, current: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "The local checkout of \(repo), where Review with Claude sessions open"
        if let current { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var set = config.prCheckouts.filter { $0.key.lowercased() != repo.lowercased() }
        set[repo] = url.path
        config.prCheckouts = set
    }

    private var validRepo: Bool {
        newRepo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            && !config.prRepos.contains(newRepo)
    }

    private func addRepo() {
        guard validRepo else { return }
        config.prRepos.append(newRepo.trimmingCharacters(in: .whitespaces))
        newRepo = ""
    }

    private var hooksText: String {
        let h = setup.hooks
        if h.installed.isEmpty { return "Not installed. They go into ~/.claude/settings.json, next to your own hooks, with a backup first." }
        if !h.current { return "Installed, but from another copy of the app or incomplete" + (h.missing.isEmpty ? "" : " (missing \(h.missing.joined(separator: ", ")))") + ". Repair points them at this copy." }
        return "Installed for \(h.installed.count) events. Sessions pick them up when they start."
    }

    private var ghText: String {
        guard setup.ghChecked else { return "Checking…" }
        switch setup.gh {
        case nil: return "Not installed. Optional: brew install gh, then gh auth login. Without it, switch pull requests off."
        case "": return "Installed but not signed in: run gh auth login in Terminal."
        case let login?: return "Signed in as \(login)."
        }
    }

    private func row(ok: Bool, optional: Bool = false, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : optional ? "minus.circle" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : optional ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The Updates section: the automatic-check switch, what the last check found, and a button.
struct UpdateSection: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var preferences: Preferences

    var body: some View {
        Toggle("Check for updates automatically", isOn: $preferences.checkForUpdates).disabled(!updates.isAvailable)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(updates.currentVersion.map { "AI Session Radar \($0)" } ?? "AI Session Radar (development build)")
                Text(statusLine).font(.system(size: 11))
                    .foregroundStyle(updates.availableRelease == nil ? .secondary : Color.accentColor)
            }
            Spacer()
            if updates.status == .checking || updates.status == .installing { ProgressView().controlSize(.small) }
            Button(updates.availableRelease == nil ? "Check Now" : "Update…") { updates.checkNow() }
                .disabled(!updates.isAvailable || updates.status == .checking || updates.status == .installing)
        }
    }

    private var statusLine: String {
        switch updates.status {
        case .checking: return "Checking…"
        case .installing: return "Installing…"
        case .available(let r): return "Version \(r.version?.description ?? r.tagName) is available."
        case .failed(let m): return "Last check failed: \(m)"
        case .upToDate, .idle:
            guard let last = updates.lastChecked else { return "Not checked yet." }
            let rel = last.formatted(.relative(presentation: .named))
            return updates.status == .upToDate ? "Up to date, checked \(rel)." : "Last checked \(rel)."
        }
    }
}

/// Hosts the settings (or welcome) view in its own window. While it is open the app shows in the Dock.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: (_ welcome: Bool, _ close: @escaping () -> Void) -> AnyView
    var onClose: () -> Void = {}

    init(makeView: @escaping (_ welcome: Bool, _ close: @escaping () -> Void) -> AnyView) { self.makeView = makeView }

    func show(welcome: Bool = false) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = welcome ? "Welcome to AI Session Radar" : "AI Session Radar Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: makeView(welcome) { [weak w] in w?.close() })
        w.center()
        w.delegate = self
        window = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        window = nil
    }
}
