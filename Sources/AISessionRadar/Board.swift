// The board window: three views of the same sessions, switched in the toolbar.
//   Board     the everyday view: four quiet columns, subagents folded into a stack under their session
//   Graph     sessions grouped by project, each subagent linked to the session that started it
//   Timeline  the last hours, a lane per session coloured by state, subagents as bars beneath
import AppKit
import SwiftUI

let kindLabels = ["permission": "Permission", "question": "Question", "plan": "Plan", "error": "Error", "files": "Wrote"]

/// The app as a solid pill with its icon, the same as in the menu: the colour sits on the
/// shape, so it reads on any background.
struct AppLabel: View {
    let key: String, name: String
    var body: some View {
        let style = appStyle(key)
        HStack(spacing: 3) {
            Image(systemName: style.symbol).font(.system(size: 9, weight: .bold))
            Text(name).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(Color(nsColor: style.text))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: style.fill)))
        .fixedSize()
    }
}

/// Context size as a thin bar where the window is known, otherwise as a number only.
struct ContextMeter: View {
    let row: Row
    var body: some View {
        if let label = row.contextLabel {
            HStack(spacing: 6) {
                if let t = row.contextTokens, let w = row.contextWindow, w > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Color.primary.opacity(0.28)).frame(width: g.size.width * min(1, CGFloat(t) / CGFloat(w)))
                        }
                    }
                    .frame(height: 3)
                }
                Text(label).font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit().fixedSize()
            }
            .help("Context of the latest reply: \(row.contextTokens ?? 0) tokens" + (row.model.map { " · \($0)" } ?? ""))
        }
    }
}

func whenText(_ row: Row) -> String {
    switch row.column {
    case "needs": return "waiting \(ago(row.waiting))"
    case "review": return "\(ago(row.waiting)) ago"
    case "working": return ago(row.waiting)
    default: return "\(ago(row.waiting)) ago"
    }
}

// MARK: - Board (everyday view)

struct QuietCard: View {
    let row: Row, colour: Color, agents: [Row]
    @ObservedObject var store: Store
    @State private var hover = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AppLabel(key: row.appKey, name: row.app)
                Text("·").foregroundStyle(.tertiary)
                Text(whenText(row)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                if let pr = row.pr { PRBadge(pr: pr) }
                Spacer(minLength: 4)
                if hover {
                    if (row.column == "review" || row.column == "done") && !row.seen {
                        Button("Seen") { store.seen(row.id) }.controlSize(.mini)
                    }
                    Button("Open") { store.open(row.id) }.controlSize(.mini)
                }
            }
            .frame(height: 16)
            Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.folder + (row.branch.map { " · \($0)" } ?? ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let detail = row.detail, row.column != "working" {
                let label = Text(verbatim: row.kind.flatMap { kindLabels[$0] }.map { "\($0): " } ?? "").foregroundColor(colour)
                Text("\(label)\(Text(verbatim: detail))")
                    .font(.system(size: 12)).foregroundStyle(row.column == "done" ? .secondary : .primary)
                    .lineLimit(row.column == "done" ? 2 : 4).fixedSize(horizontal: false, vertical: true)
            } else if row.column == "working", let prompt = row.lastPrompt {
                Text(verbatim: prompt).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.column == "review" && !row.files.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(row.files, id: \.self) { f in
                        Label(f.split(separator: "/").suffix(2).joined(separator: "/"), systemImage: "doc.text")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(f)
                    }
                }
            }
            ContextMeter(row: row).padding(.top, 1)
            if !agents.isEmpty { agentStack }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(row.column == "needs" ? colour.opacity(0.9) : Color.primary.opacity(hover ? 0.18 : 0.08),
                          lineWidth: row.column == "needs" ? 1.2 : 0.6))
        // The deck: one or two card edges peek out underneath while subagents run.
        .background(alignment: .bottom) {
            if !agents.isEmpty && !expanded {
                ZStack(alignment: .bottom) {
                    if agents.count > 1 { deckEdge.padding(.horizontal, 10).offset(y: 8) }
                    deckEdge.padding(.horizontal, 5).offset(y: 4)
                }
            }
        }
        .padding(.bottom, !agents.isEmpty && !expanded ? (agents.count > 1 ? 8 : 4) : 0)
        .opacity(row.column == "done" && row.seen ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.open(row.id) }
        .help(row.cwd)
    }

    private var deckEdge: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6))
            .frame(height: 14)
    }

    private var agentStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 10.5))
                    Text(stackSummary).font(.system(size: 11)).lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(colour)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(agents) { a in AgentLine(agent: a, colour: colour) }
            }
        }
        .padding(.top, 3)
    }

    private var stackSummary: String {
        let types = agents.map(\.agentType)
        let shown = types.prefix(2).joined(separator: ", ") + (types.count > 2 ? ", +\(types.count - 2)" : "")
        return "\(agents.count) subagent\(agents.count == 1 ? "" : "s") · \(shown)"
    }
}

/// One subagent inside an opened stack (or on its own when its session is in another column).
struct AgentLine: View {
    let agent: Row, colour: Color
    var parent: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1).fill(colour.opacity(agent.background ? 0.35 : 0.7)).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(agent.agentType).font(.system(size: 11, weight: .semibold))
                    if agent.background { Text("background").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 4)
                    Text(ago(agent.waiting)).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(agent.name).font(.system(size: 11.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let tool = agent.detail {
                    Text(tool).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let parent { Text("in \(parent)").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .help("\(agent.tools) tool calls")
    }
}

struct QuietColumn: View {
    let style: ColumnStyle
    @ObservedObject var store: Store

    var body: some View {
        let rows = store.rows.filter { $0.column == style.key }
        let sessions = rows.filter { !$0.isAgent }
        let ids = Set(sessions.map(\.id))
        let orphans = rows.filter { $0.isAgent && !ids.contains($0.parentId ?? "") }
        let colour = Color(nsColor: style.colour)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(colour).frame(width: 7, height: 7)
                Text(style.title).font(.system(size: 12, weight: .semibold))
                Text("\(sessions.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if rows.isEmpty {
                        Text("Nothing here").font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    ForEach(sessions) { row in
                        QuietCard(row: row, colour: colour, agents: rows.filter { $0.parentId == row.id }, store: store)
                    }
                    ForEach(orphans) { a in
                        AgentLine(agent: a, colour: colour, parent: a.parentName)
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                            .onTapGesture(count: 2) { store.open(a.id) }
                    }
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
        }
        .padding(10)
        .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
    }
}

struct QuietBoard: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(columns, id: \.key) { QuietColumn(style: $0, store: store) }
        }
    }
}

// MARK: - Window

enum RadarView: String, CaseIterable { case board = "Board", graph = "Graph", timeline = "Timeline", prs = "Pull requests" }

struct BoardView: View {
    @ObservedObject var store: Store
    @AppStorage("radarView") private var view: RadarView = .board

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("View", selection: $view) {
                    ForEach(RadarView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                ForEach(columns.prefix(3), id: \.key) { c in
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: c.colour)).frame(width: 6, height: 6)
                        Text("\(store.counts[c.key] ?? 0)").fontWeight(.semibold).monospacedDigit()
                        Text(c.title.lowercased()).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                if let n = store.counts["agents"], n > 0 {
                    Text("\(n) subagent\(n == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    ForEach([("desktop", "Desktop"), ("vscode", "VS Code"), ("ghostty", "Ghostty"), ("terminal", "Terminal")], id: \.0) {
                        AppLabel(key: $0.0, name: $0.1)
                    }
                }
                Button("Mark finished as seen") { store.seen("all") }.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            // ⌘1 to ⌘4 switch views.
            .background {
                ForEach(Array(RadarView.allCases.enumerated()), id: \.offset) { i, v in
                    Button("") { view = v }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).hidden()
                }
            }
            if let error = store.error {
                Text(error).font(.system(size: 12)).foregroundColor(.red).padding(.bottom, 6)
            }
            Group {
                switch view {
                case .board: QuietBoard(store: store)
                case .graph: GraphView(store: store)
                case .timeline: TimelineView(store: store)
                case .prs: PRView(store: store)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(minWidth: 1000, minHeight: 480)
    }
}

/// Owns the board window. While it is open the app shows in the Dock and ⌘-Tab.
final class BoardWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let store: Store

    init(store: Store) { self.store = store }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "AI Session Radar"
            w.titlebarAppearsTransparent = false
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: BoardView(store: store))
            w.delegate = self
            w.setFrameAutosaveName("ClaudeRadarBoard")
            if !w.setFrameUsingName("ClaudeRadarBoard") { w.center() }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open on screen; the Dock icon only exists then.
    var isOpen: Bool { window?.isVisible ?? false }

    var onClose: () -> Void = {}

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
