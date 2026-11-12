// Graph view: sessions grouped by project (their folder), each subagent linked to the
// session that started it. Node borders carry the state colour; background subagents
// have dashed borders and dashed links. Finished sessions shrink to chips at the bottom,
// unless a subagent of theirs is still running.
import SwiftUI

private let nodeWidth: CGFloat = 230, agentWidth: CGFloat = 230
private let sessionHeight: CGFloat = 62, agentHeight: CGFloat = 46, agentGap: CGFloat = 8, linkWidth: CGFloat = 46

struct GraphView: View {
    @ObservedObject var store: Store

    var body: some View {
        let sessions = store.rows.filter { !$0.isAgent }
        let projects = Dictionary(grouping: sessions, by: projectName)
        // Projects with something waiting on you first, then by how much is going on.
        let order = projects.keys.sorted { a, b in
            let ra = rank(projects[a]!), rb = rank(projects[b]!)
            return ra != rb ? ra < rb : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        ScrollView {
            if sessions.isEmpty {
                Text("No Claude sessions running").foregroundStyle(.secondary).padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: nodeWidth + linkWidth + agentWidth + 40), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(order, id: \.self) { name in
                    ProjectCluster(name: name, sessions: projects[name]!, agents: store.rows.filter(\.isAgent), store: store)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func rank(_ rows: [Row]) -> Int {
        if rows.contains(where: { $0.column == "needs" }) { return 0 }
        if rows.contains(where: { $0.column == "review" }) { return 1 }
        if rows.contains(where: { $0.column == "working" }) { return 2 }
        return 3
    }
}

struct ProjectCluster: View {
    let name: String, sessions: [Row], agents: [Row]
    @ObservedObject var store: Store

    var body: some View {
        // A finished session with a subagent still running keeps its node, so the subagent
        // stays linked to it instead of disappearing with the chip.
        let parents = Set(agents.compactMap(\.parentId))
        let active = sessions.filter { $0.column != "done" || parents.contains($0.id) }
        let finished = sessions.filter { $0.column == "done" && !parents.contains($0.id) }
        let branches = Array(Set(sessions.compactMap(\.branch))).sorted()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let b = branches.first {
                    Text(branches.count > 1 ? "\(b) +\(branches.count - 1)" : b)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            ForEach(active) { s in
                SessionBranch(session: s, agents: agents.filter { $0.parentId == s.id }, store: store)
            }
            if !finished.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(finished) { s in
                        HStack(spacing: 4) {
                            Image(systemName: appStyle(s.appKey).symbol).font(.system(size: 9)).foregroundColor(Color(nsColor: appStyle(s.appKey).ink))
                            Text(s.name).font(.system(size: 11)).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color(nsColor: stateColour("done")).opacity(0.6), lineWidth: 0.8))
                        .opacity(s.seen ? 0.55 : 1)
                        .frame(maxWidth: 260)
                        .onTapGesture(count: 2) { store.open(s.id) }
                        .help(s.detail ?? s.name)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3])))
    }
}

/// A session node with its subagents to the right, joined by curved links.
struct SessionBranch: View {
    let session: Row, agents: [Row]
    @ObservedObject var store: Store

    var body: some View {
        let stackHeight = agents.isEmpty ? 0 : CGFloat(agents.count) * agentHeight + CGFloat(agents.count - 1) * agentGap
        let height = max(sessionHeight, stackHeight)
        HStack(alignment: .center, spacing: 0) {
            SessionNode(row: session, store: store)
            if !agents.isEmpty {
                Canvas { ctx, size in
                    let start = CGPoint(x: 0, y: size.height / 2)
                    let top = (size.height - stackHeight) / 2
                    for (i, a) in agents.enumerated() {
                        let end = CGPoint(x: size.width, y: top + agentHeight / 2 + CGFloat(i) * (agentHeight + agentGap))
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: size.width * 0.55, y: start.y),
                                      control2: CGPoint(x: size.width * 0.45, y: end.y))
                        ctx.stroke(path, with: .color(Color(nsColor: stateColour("working")).opacity(0.75)),
                                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: a.background ? [4, 3] : []))
                    }
                }
                .frame(width: linkWidth, height: height)
                VStack(spacing: agentGap) {
                    ForEach(agents) { AgentNode(row: $0, store: store) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: height)
    }
}

struct SessionNode: View {
    let row: Row
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        let colour = Color(nsColor: stateColour(row.column))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                AppLabel(key: row.appKey, name: row.app)
                Spacer(minLength: 4)
                Text(whenText(row)).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(row.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            if let d = row.detail, row.column == "needs" || row.column == "review" {
                Text(d).font(.system(size: 11)).foregroundColor(colour).lineLimit(1)
            } else if let c = row.contextLabel {
                Text(c).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: nodeWidth, height: sessionHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(colour, lineWidth: hover ? 2.4 : 1.8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.open(row.id) }
        .help((row.detail ?? row.lastPrompt ?? row.name) + "\nDouble-click opens the session")
    }
}

struct AgentNode: View {
    let row: Row
    @ObservedObject var store: Store

    var body: some View {
        let colour = Color(nsColor: stateColour("working"))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(row.agentType).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if row.background { Text("background").font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer(minLength: 4)
                Text(ago(row.waiting)).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(row.detail ?? row.name).font(.system(size: 10.5, design: row.detail == nil ? .default : .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(width: agentWidth, height: agentHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(colour.opacity(0.8), style: StrokeStyle(lineWidth: 1.1, dash: row.background ? [4, 3] : [])))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(row.id) }
        .help("\(row.name)\n\(row.tools) tool calls · double-click opens the session")
    }
}

/// Lays children out left to right, wrapping onto new lines (for the finished-session chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
