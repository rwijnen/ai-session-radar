// Pull requests view: open PRs in the watched repos and every PR that involves you, grouped by
// who has to act. Each row: repo and number, title, Jira key, author and target branch, checks,
// review state, size, comments, the AI review verdict and the Claude session on the PR's branch.
// Hovering the AI review label opens the review itself, rendered as GitHub renders it.
import SwiftUI
import WebKit

struct PRView: View {
    @ObservedObject var store: Store

    var body: some View {
        if !store.prsEnabled {
            VStack(spacing: 8) {
                Text("Pull requests are switched off").font(.system(size: 14, weight: .semibold))
                Text("Turn them on under Settings › Pull requests. They are read through the GitHub CLI (gh).")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(prGroups, id: \.key) { g in
                    let n = store.prs.filter { $0.group == g.key }.count
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: g.colour)).frame(width: 6, height: 6)
                        Text("\(n)").fontWeight(.semibold).monospacedDigit()
                        Text(g.title.lowercased()).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                Spacer()
                Text(source).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                Button { store.refreshPRs() } label: { Image(systemName: "arrow.clockwise") }
                    .controlSize(.small).help("Refresh now (it refreshes every 2 minutes)")
            }
            if let e = store.prError {
                Text("GitHub: \(e)").font(.system(size: 12)).foregroundColor(Color(nsColor: failColour))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.prs.isEmpty {
                        Text(store.prFetched == nil ? "Reading pull requests…" : "No open pull requests")
                            .foregroundStyle(.secondary).padding(30)
                    }
                    ForEach(prGroups, id: \.key) { g in
                        let group = store.prs.filter { $0.group == g.key }
                        if !group.isEmpty {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: g.colour)).frame(width: 7, height: 7)
                                Text(g.title).font(.system(size: 12, weight: .semibold))
                                Text("\(group.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.top, 10).padding(.leading, 2)
                            ForEach(group) { PRRow(pr: $0, store: store) }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private var source: String {
        let repos = store.prWatched.isEmpty ? "no watched repos" : store.prWatched.joined(separator: ", ")
        let when = store.prFetched.map { "updated " + ago(Int(Date().timeIntervalSince($0))) + " ago" } ?? ""
        return "\(repos) + PRs that involve you · \(when)"
    }
}

struct PRRow: View {
    let pr: PR
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        let colour = Color(nsColor: prColour(pr.group))
        let now = Date().timeIntervalSince1970
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(colour).frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Double-click opens the pull request on GitHub")
                HStack(spacing: 6) {
                    Text("\(pr.repoName) #\(pr.number)").foregroundStyle(.secondary)
                    if let j = pr.jira { Pill(text: j, style: .tint(Color(nsColor: columns[1].colour))) }
                    Avatar(login: pr.author, me: pr.mine)
                    Text("\(pr.mine ? "you" : pr.author) → \(pr.base)").foregroundStyle(.secondary)
                    Text("· updated \(ago(Int(now - pr.updatedAt))) ago").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5)).lineLimit(1)
                HStack(spacing: 6) {
                    // Why it is in its group, unless a pill already says it (failed checks, your review).
                    if !pr.reason.contains("check") && !pr.requestedMe {
                        Text(pr.reason).font(.system(size: 11.5, weight: .medium)).foregroundColor(colour)
                    }
                    checksPills
                    reviewPill
                    if pr.mergeable == "CONFLICTING" { Pill(text: "Merge conflict", style: .solid(failColour)) }
                    if pr.draft { Pill(text: "Draft", style: .soft) }
                    if let ai = pr.ai { AIReviewLabel(review: ai, pr: pr) }
                    ForEach(store.rows.filter { !$0.isAgent && $0.pr?.id == pr.id }) { s in
                        Button { store.open(s.id) } label: {
                            Pill(text: "Claude session: \(sessionState(s))", style: .tint(Color(nsColor: stateColour(s.column))))
                        }
                        .buttonStyle(.plain).help("\(s.name) · click opens the session")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Text("+\(pr.additions)").foregroundColor(Color(nsColor: passColour))
                    Text("−\(pr.deletions)").foregroundColor(Color(nsColor: failColour))
                }
                .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                Text("\(pr.files) files · \(pr.comments) comment\(pr.comments == 1 ? "" : "s")")
                Text("open \(ago(Int(now - pr.createdAt)))")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.vertical, 9).padding(.trailing, 12)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(hover ? 0.18 : 0.08), lineWidth: 0.6))
        .opacity(pr.group == "stale" ? 0.65 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { openURL(pr.url) }
    }

    @ViewBuilder private var checksPills: some View {
        let c = pr.checks
        if c.failed > 0 {
            Pill(text: "✗ \(c.failed) failed", style: .solid(failColour)).help("Failed: " + c.failing.joined(separator: ", "))
            Text(c.failing.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        if c.running > 0 { Pill(text: "◌ \(c.running) running", style: .tint(Color(nsColor: stateColour("working")))) }
        if c.passed > 0 && c.failed == 0 { Pill(text: "✓ \(c.passed) passed", style: .tint(Color(nsColor: passColour))) }
        if c.passed + c.failed + c.running == 0 && c.skipped == 0 { Pill(text: "no checks", style: .soft) }
    }

    @ViewBuilder private var reviewPill: some View {
        if pr.requestedMe {
            Pill(text: "Your review requested", style: .solid(columns[0].colour))
        } else {
            switch pr.review {
            case "APPROVED": Pill(text: "Approved", style: .tint(Color(nsColor: passColour)))
            case "CHANGES_REQUESTED": Pill(text: "Changes requested", style: .tint(Color(nsColor: failColour)))
            case "REVIEW_REQUIRED": Pill(text: "Review required", style: .soft)
                .help(pr.requested.isEmpty ? "No reviewer requested" : "Requested: " + pr.requested.joined(separator: ", "))
            default: EmptyView()
            }
        }
    }

    private func sessionState(_ r: Row) -> String {
        ["needs": "needs you", "review": "to review", "working": "working"][r.column] ?? "done"
    }
}

/// A small label. Solid fills carry white (dark-mode: near-black) text; tints colour the text.
struct Pill: View {
    enum Style { case solid(NSColor), tint(Color), soft }
    let text: String, style: Style
    var body: some View {
        let label = Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5).fixedSize()
        switch style {
        case .solid(let c):
            label.foregroundColor(Color(nsColor: onStateColour)).background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c)))
        case .tint(let c):
            label.foregroundColor(c).background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.14)))
        case .soft:
            label.foregroundStyle(.secondary).background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
        }
    }
}

/// Initials in a circle; your own PRs get the accent colour.
struct Avatar: View {
    let login: String, me: Bool
    var body: some View {
        let parts = login.split(whereSeparator: { "-_.".contains($0) })
        let initials = (parts.count > 1 ? String(parts[0].prefix(1)) + String(parts[1].prefix(1)) : String(login.prefix(2))).uppercased()
        Text(initials).font(.system(size: 8.5, weight: .bold))
            .foregroundColor(me ? .white : .secondary)
            .frame(width: 17, height: 17)
            .background(Circle().fill(me ? Color.accentColor : Color.primary.opacity(0.1)))
            .help(login)
    }
}

// MARK: - AI review

/// "AI review: changes needed". Hover (or click) opens the review; it stays open while you read,
/// and closes on a click outside or Esc.
struct AIReviewLabel: View {
    let review: AIReview, pr: PR
    @State private var show = false
    @State private var hovering = false

    var body: some View {
        let colour: NSColor = review.verdict == "APPROVE" ? passColour : review.verdict == "REQUEST_CHANGES" ? failColour : columns[3].colour
        let text = "AI review: \(review.label)" + (review.current ? "" : " · older commit")
        Group {
            if review.current { Pill(text: text, style: .tint(Color(nsColor: colour))) }
            else { Pill(text: text, style: .soft) }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: colour).opacity(hovering ? 0.7 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if hovering { show = true } }
            }
        }
        .onTapGesture { show.toggle() }
        .popover(isPresented: $show, arrowEdge: .bottom) { AIReviewPanel(review: review, pr: pr) }
    }
}

struct AIReviewPanel: View {
    let review: AIReview, pr: PR

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text("AI review of \(pr.repoName) #\(pr.number)").font(.system(size: 12.5, weight: .semibold))
                Text(review.current ? "head \(String(review.sha.prefix(7)))" : "older commit \(String(review.sha.prefix(7))), the PR has moved on")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("· \(ago(Int(Date().timeIntervalSince1970 - review.at))) ago").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if let u = review.url { Button("Open on GitHub") { openURL(u) }.controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            HTMLView(html: review.html)
        }
        .frame(width: 720, height: 600)
        // Opaque: the popover's see-through material would show the pills underneath as blurs.
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// GitHub's rendered HTML of a comment, styled like GitHub in light and dark. Links open in the browser.
struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(page, baseURL: URL(string: "https://github.com"))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private var page: String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 12.5px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; margin: 14px 18px 24px; color: #1f2328; }
        h1, h2 { font-size: 16px; margin: 0 0 10px; padding-bottom: 6px; border-bottom: 1px solid #d1d9e0; }
        h3 { font-size: 14px; margin: 18px 0 6px; } h4 { font-size: 13px; margin: 16px 0 6px; }
        p { margin: 6px 0; }
        table { border-collapse: collapse; margin: 8px 0; display: block; overflow-x: auto; max-width: 100%; }
        th, td { border: 1px solid #d1d9e0; padding: 4px 9px; vertical-align: top; text-align: left; }
        th { background: #f6f8fa; font-weight: 600; } tr:nth-child(2n) td { background: rgba(246,248,250,.6); }
        code { font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(175,184,193,.2); padding: 1px 4px; border-radius: 4px; }
        pre { background: rgba(175,184,193,.14); padding: 10px 12px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 11px; }
        details { margin: 12px 0; } summary { cursor: pointer; color: #59636e; }
        a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
        sub, .color-fg-muted { color: #59636e; } hr { border: 0; border-top: 1px solid #d1d9e0; margin: 14px 0; }
        ul, ol { padding-left: 22px; } img { max-width: 100%; }
        @media (prefers-color-scheme: dark) {
          body { color: #e6edf3; } h1, h2, hr { border-color: #3d444d; } th, td { border-color: #3d444d; }
          th { background: #151b23; } tr:nth-child(2n) td { background: rgba(21,27,35,.5); }
          a { color: #4493f8; } summary, sub { color: #9198a1; }
        }
        </style></head><body>\(html)</body></html>
        """
    }
}

// MARK: - On a session card

/// "PR #156 ✗ 2" on a session card, coloured by who has to act; click opens the PR.
struct PRBadge: View {
    let pr: PRLink
    var body: some View {
        let c = pr.checks
        let mark = c.failed > 0 ? " ✗ \(c.failed)" : c.running > 0 ? " ◌" : c.passed > 0 ? " ✓" : ""
        Button { openURL(pr.url) } label: {
            Pill(text: "PR #\(pr.number)\(mark)", style: pr.group == "you" ? .solid(prColour(pr.group)) : .tint(Color(nsColor: prColour(pr.group))))
        }
        .buttonStyle(.plain)
        .help("\(pr.reason)" + (pr.aiVerdict.map { " · AI review \($0.lowercased().replacingOccurrences(of: "_", with: " "))" } ?? "") + " · click opens the PR")
    }
}
