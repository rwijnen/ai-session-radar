// Timeline view: the last 1, 3 or 8 hours as turn-taking. Each session gets a lane with a
// centre line: Claude's turns (working) sit above it, yours (Needs you, Ready to review)
// below it as blocks with their minutes. On the right: how long the session waited for
// you in the window, and its state now. Done is empty track, so only turns show. Sessions
// with nothing in the window fold into one line. Subagents are thin lines above Claude's turn.
//
// History is recorded by the hook from the moment it was installed; before that, and
// before a session's first recorded change, the lane is empty.
import SwiftUI

private let labelWidth: CGFloat = 220, summaryWidth: CGFloat = 150
private let claudeBar: CGFloat = 9, youBar: CGFloat = 17, agentLine: CGFloat = 3, agentGap: CGFloat = 2

/// White on the deeper light-mode state colours, near-black on the lighter dark-mode ones.
let onStateColour = dynamic(0xFFFFFF, 0x1C1C1E)

/// One turn in the window: Claude's (working) or yours (needs you, ready to review).
struct Turn {
    enum Kind { case claude, needs, review }
    let kind: Kind, from: Double, to: Double
    var seconds: Double { to - from }
    var yours: Bool { kind != .claude }
    var colour: NSColor { stateColour(kind == .claude ? "working" : kind == .needs ? "needs" : "review") }
    var title: String { kind == .claude ? "Claude working" : kind == .needs ? "Needs you" : "Ready to review" }
}

/// A session's turns between `start` and `now`, from its recorded history.
func turns(_ s: Row, start: Double, now: Double) -> [Turn] {
    let h = s.history
    var out: [Turn] = []
    for (i, entry) in h.enumerated() {
        let end = i + 1 < h.count ? h[i + 1].at : now
        let from = max(entry.at, start)
        guard end > from else { continue }
        let kind: Turn.Kind? = ["working": .claude, "needs_you": .needs, "review": .review][entry.state] ?? nil
        if let kind { out.append(Turn(kind: kind, from: from, to: end)) }
    }
    return out
}

func waited(_ t: [Turn]) -> Double { t.filter(\.yours).reduce(0) { $0 + $1.seconds } }

/// Tick spacing for the range: 15 min, 30 min or an hour.
private func ticks(_ start: Double, _ end: Double, _ hours: Int) -> [Double] {
    let step: Double = hours == 1 ? 900 : hours == 3 ? 1800 : 3600
    let first = (start / step).rounded(.up) * step
    return stride(from: first, through: end - step / 3, by: step).map { $0 }
}

struct TimelineView: View {
    @ObservedObject var store: Store
    @AppStorage("timelineHours") private var hours: Int = 1
    @State private var showQuiet = false

    var body: some View {
        let now = (store.updated ?? Date()).timeIntervalSince1970
        let start = now - Double(hours) * 3600
        let sessions = store.rows.filter { !$0.isAgent }
        let withTurns = sessions.map { (row: $0, turns: turns($0, start: start, now: now)) }
        // Active: anything happened in the window, or it is not done now.
        let active = withTurns.filter { !$0.turns.isEmpty || $0.row.column != "done" }
            .sorted { a, b in
                let ra = rank(a.row), rb = rank(b.row)
                return ra != rb ? ra < rb : waited(a.turns) > waited(b.turns)
            }
        let quiet = withTurns.filter { $0.turns.isEmpty && $0.row.column == "done" }.map(\.row)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Picker("Range", selection: $hours) {
                    Text("1 hour").tag(1); Text("3 hours").tag(3); Text("8 hours").tag(8)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Legend()
                Spacer()
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 16)
                Axis(start: start, end: now, hours: hours)
                Color.clear.frame(width: summaryWidth, height: 16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sessions.isEmpty {
                        Text("No Claude sessions running").foregroundStyle(.secondary).padding(30)
                    }
                    ForEach(active, id: \.row.id) { s in
                        TurnLane(session: s.row, turns: s.turns,
                                 agents: agentSpans(s.row, start: start, now: now),
                                 start: start, now: now, hours: hours, store: store)
                    }
                    if !quiet.isEmpty { quietLine(quiet, start: start, now: now) }
                }
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func quietLine(_ quiet: [Row], start: Double, now: Double) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showQuiet.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showQuiet ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                Text("\(quiet.count) quiet session\(quiet.count == 1 ? "" : "s")").font(.system(size: 11.5, weight: .medium))
                Text(quiet.map(\.name).joined(separator: ", ")).font(.system(size: 11.5)).lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nothing happened in these sessions in this time range")
        if showQuiet {
            ForEach(quiet) { r in
                TurnLane(session: r, turns: [], agents: [], start: start, now: now, hours: hours, store: store)
                    .opacity(0.6)
            }
        }
    }

    private func rank(_ r: Row) -> Int { ["needs": 0, "review": 1, "working": 2][r.column] ?? 3 }

    /// Subagents in the window: finished ones from the history, running ones up to now.
    private func agentSpans(_ s: Row, start: Double, now: Double) -> [AgentSpan] {
        let finished = s.agentHistory.filter { ($0.end ?? now) > start }
        let running = store.rows.filter { $0.parentId == s.id }.map {
            AgentSpan(type: $0.agentType, description: $0.name, start: now - Double($0.waiting), end: nil, background: $0.background)
        }
        return (finished + running).sorted { $0.start < $1.start }
    }
}

/// What each mark means, drawn the way the lanes draw it.
struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            item(RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: stateColour("working"))).frame(width: 16, height: 6), "Claude's turn")
            item(RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: stateColour("needs"))).frame(width: 16, height: 9), "Needs you")
            item(RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: stateColour("review"))).frame(width: 16, height: 9), "Ready to review")
            item(Capsule().fill(Color(nsColor: stateColour("working")).opacity(0.5)).frame(width: 16, height: 3), "subagent")
        }
    }
    private func item(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 4) { mark; Text(text).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
}

/// Time ticks along the top, with "now" at the right edge.
struct Axis: View {
    let start: Double, end: Double, hours: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(ticks(start, end, hours), id: \.self) { t in
                    Text(Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize()
                        .position(x: CGFloat((t - start) / (end - start)) * g.size.width, y: 7)
                }
                Text("now").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).fixedSize()
                    .position(x: g.size.width - 10, y: 7)
            }
        }
        .frame(height: 16)
    }
}

struct TurnLane: View {
    let session: Row, turns: [Turn], agents: [AgentSpan], start: Double, now: Double, hours: Int
    @ObservedObject var store: Store

    var body: some View {
        let rows = agentRows
        let agentsHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * (agentLine + agentGap) + 2
        let lineY = agentsHeight + claudeBar + 3
        let height = lineY + 1 + 3 + youBar
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    AppLabel(key: session.appKey, name: session.app)
                    Text(session.folder).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(width: labelWidth - 12, alignment: .leading)
            .padding(.trailing, 12)

            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(ticks(start, now, hours), id: \.self) { t in
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1, height: height).offset(x: x(t, w))
                    }
                    // Subagents: thin lines above Claude's turn, one row per overlap.
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        ForEach(Array(row.enumerated()), id: \.offset) { _, a in
                            let x0 = x(max(a.start, start), w), x1 = x(a.end ?? now, w)
                            Capsule()
                                .fill(Color(nsColor: stateColour("working")).opacity(a.background ? 0.3 : 0.5))
                                .frame(width: max(3, x1 - x0), height: agentLine)
                                .offset(x: x0, y: CGFloat(i) * (agentLine + agentGap))
                                .help("\(a.type)" + (a.description.map { ": \($0)" } ?? "") + " · \(ago(Int((a.end ?? now) - a.start)))"
                                      + (a.end == nil ? " · running" : "") + (a.background ? " · background" : ""))
                        }
                    }
                    // The centre line: Claude above, you below.
                    Rectangle().fill(Color.primary.opacity(0.16)).frame(width: w, height: 1).offset(y: lineY)
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                        let x0 = x(t.from, w), x1 = x(t.to, w), width = max(2, x1 - x0)
                        if t.yours {
                            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: t.colour))
                                .frame(width: width, height: youBar)
                                .overlay {
                                    if width >= 28 {
                                        Text(ago(Int(t.seconds))).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                                            .foregroundColor(Color(nsColor: onStateColour)).lineLimit(1)
                                    }
                                }
                                .offset(x: x0, y: lineY + 4)
                                .help(help(t))
                        } else {
                            RoundedRectangle(cornerRadius: 2.5).fill(Color(nsColor: t.colour).opacity(0.85))
                                .frame(width: width, height: claudeBar)
                                .offset(x: x0, y: agentsHeight)
                                .help(help(t))
                        }
                    }
                    Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1, height: height).offset(x: w - 1)
                }
            }
            .frame(height: height)

            summary.frame(width: summaryWidth - 14, alignment: .leading).padding(.leading, 14)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(session.id) }
        .help("Double-click opens the session")
    }

    /// How long it waited for you in this range, and its state now.
    private var summary: some View {
        let total = waited(turns)
        return VStack(alignment: .leading, spacing: 4) {
            Text(total >= 1 ? "waited \(ago(Int(total)))" : "no wait")
                .font(.system(size: 11.5, weight: total >= 600 ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(total >= 1 ? .primary : .tertiary)
            if let title = ["needs": "Needs you", "review": "To review", "working": "Working"][session.column] {
                Text("\(title) · \(ago(session.waiting))")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit().lineLimit(1)
                    .foregroundColor(Color(nsColor: onStateColour))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: stateColour(session.column))))
            } else {
                Text("done · \(ago(session.waiting)) ago").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Subagents placed in rows so overlapping ones don't cover each other (at most three rows).
    private var agentRows: [[AgentSpan]] {
        var rows: [[AgentSpan]] = []
        for a in agents where (a.end ?? now) > start {
            if let i = rows.firstIndex(where: { ($0.last?.end ?? now) <= a.start }) { rows[i].append(a) }
            else if rows.count < 3 { rows.append([a]) }
            else { rows[2].append(a) }
        }
        return rows
    }

    private func help(_ t: Turn) -> String {
        let f = { (d: Double) in Date(timeIntervalSince1970: d).formatted(date: .omitted, time: .shortened) }
        return "\(t.title) · \(ago(Int(t.seconds))) (\(f(t.from))–\(f(t.to)))"
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { max(0, min(w, CGFloat((t - start) / (now - start)) * w)) }
}
