// Timeline view: the last 1, 3 or 8 hours, or under Custom everything from a chosen date and
// time up to now (at most a week back), as turn-taking. Each session gets a lane with a centre
// line: Claude's turns (working) sit above it, yours (Needs you, Ready to review) below it as
// blocks with their minutes. On the right: how long the session waited for you in the window,
// and its state now. Done is empty track, so only turns show. Sessions with nothing in the
// window fold into one line; sessions closed since keep their lane up to where they closed.
// Subagents are thin lines above Claude's turn.
//
// History is recorded by the hook from the moment it was installed, and kept a week; before
// that, and before a session's first recorded change, the lane is empty.
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

/// How far back the Custom range can start: the hook keeps a week of state history
/// (`HISTORY_SECONDS` in session_radar/hook.py), and the files of closed sessions as long.
let timelineMaxBack: Double = 7 * 24 * 3600
/// The shortest Custom range, so the lanes never shrink to nothing.
let timelineMinSpan: Double = 15 * 60
/// The range picker's tag for Custom; the presets are tagged with their hours.
private let customRange = 0

/// Where the Custom range starts: the chosen moment, kept within the week the hook keeps and at
/// least a quarter of an hour before now. Until one is chosen: the whole hour 24 hours back.
func customStart(_ from: Double, now: Double) -> Double {
    guard from > 0 else {
        let dayBack = Date(timeIntervalSince1970: now - 24 * 3600)
        return (Calendar.current.dateInterval(of: .hour, for: dayBack)?.start ?? dayBack).timeIntervalSince1970
    }
    return min(now - timelineMinSpan, max(now - timelineMaxBack, from))
}

/// Tick spacing for a range of `span` seconds: 15 or 30 minutes, 1, 2, 3, 6 or 12 hours, or a
/// day, so the axis keeps eight labels or fewer.
func tickStep(_ span: Double) -> Double {
    let steps: [(hours: Double, step: Double)] = [(1, 900), (3, 1800), (8, 3600), (16, 7200), (24, 10800),
                                                  (48, 21600), (96, 43200)]
    return steps.first { span <= $0.hours * 3600 + 1 }?.step ?? 86400
}

/// Ticks on whole local wall-clock times (quarter hours, hours, every few hours from midnight, or
/// midnight), also across a daylight-saving change.
func ticks(_ start: Double, _ end: Double, calendar cal: Calendar = .current) -> [Double] {
    let step = tickStep(end - start), last = end - step / 3
    var out: [Double] = []
    var day = cal.startOfDay(for: Date(timeIntervalSince1970: start))
    while day.timeIntervalSince1970 <= last {
        var c = cal.dateComponents([.year, .month, .day], from: day)
        for minute in stride(from: 0, to: 24 * 60, by: Int(step / 60)) {
            c.hour = minute / 60; c.minute = minute % 60
            guard let t = cal.date(from: c)?.timeIntervalSince1970 else { continue }
            if t >= start, t <= last, t > (out.last ?? -.infinity) { out.append(t) }
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
    }
    return out
}

/// A tick's label: its time, or at midnight the weekday and day, so a range across days stays
/// readable.
func tickLabel(_ t: Double) -> String {
    let date = Date(timeIntervalSince1970: t)
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return c.hour == 0 && c.minute == 0
        ? date.formatted(.dateTime.weekday(.abbreviated).day())
        : date.formatted(date: .omitted, time: .shortened)
}

struct TimelineView: View {
    @ObservedObject var store: Store
    @AppStorage("timelineHours") private var range: Int = 1
    @AppStorage("timelineFrom") private var from: Double = 0
    @State private var showQuiet = false

    var body: some View {
        let now = (store.updated ?? Date()).timeIntervalSince1970
        let start = range == customRange ? customStart(from, now: now) : now - Double(range) * 3600
        let sessions = store.rows.filter { !$0.isAgent }
        let withTurns = (sessions + store.closed).map { (row: $0, turns: turns($0, start: start, now: now)) }
        // Active: anything happened in the window, or it is open and not done now.
        let active = withTurns.filter { !$0.turns.isEmpty || ($0.row.column != "done" && !$0.row.closed) }
            .sorted { a, b in
                let ra = rank(a.row), rb = rank(b.row)
                return ra != rb ? ra < rb : waited(a.turns) > waited(b.turns)
            }
        // Quiet: open sessions with nothing in the window. Closed ones with nothing in it leave.
        let quiet = withTurns.filter { $0.turns.isEmpty && $0.row.column == "done" && !$0.row.closed }.map(\.row)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Picker("Range", selection: $range) {
                    Text("1 hour").tag(1); Text("3 hours").tag(3); Text("8 hours").tag(8)
                    Text("Custom").tag(customRange)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if range == customRange { CustomRange(from: $from, now: now) }
                Legend()
                Spacer()
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 16)
                Axis(start: start, end: now)
                Color.clear.frame(width: summaryWidth, height: 16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sessions.isEmpty && active.isEmpty {
                        Text("No Claude sessions running").foregroundStyle(.secondary).padding(30)
                    }
                    ForEach(active, id: \.row.id) { s in
                        TurnLane(session: s.row, turns: s.turns,
                                 agents: agentSpans(s.row, start: start, now: now),
                                 start: start, now: now, store: store)
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
                TurnLane(session: r, turns: [], agents: [], start: start, now: now, store: store)
                    .opacity(0.6)
            }
        }
    }

    /// Who has to act first; closed sessions last.
    private func rank(_ r: Row) -> Int { r.closed ? 4 : ["needs": 0, "review": 1, "working": 2][r.column] ?? 3 }

    /// Subagents in the window: finished ones from the history, running ones up to now.
    private func agentSpans(_ s: Row, start: Double, now: Double) -> [AgentSpan] {
        let finished = s.agentHistory.filter { ($0.end ?? now) > start }
        let running = store.rows.filter { $0.parentId == s.id }.map {
            AgentSpan(type: $0.agentType, description: $0.name, start: now - Double($0.waiting), end: nil, background: $0.background)
        }
        return (finished + running).sorted { $0.start < $1.start }
    }
}

/// The Custom range: from a date and time up to now, within the week of history the hook keeps.
struct CustomRange: View {
    @Binding var from: Double
    let now: Double
    var body: some View {
        let value = Binding(get: { Date(timeIntervalSince1970: customStart(from, now: now)) },
                            set: { from = $0.timeIntervalSince1970 })
        let earliest = Date(timeIntervalSince1970: now - timelineMaxBack)
        let latest = Date(timeIntervalSince1970: now - timelineMinSpan)
        HStack(spacing: 6) {
            Text("from").font(.system(size: 11.5)).foregroundStyle(.secondary)
            DatePicker("From", selection: value, in: earliest...latest, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact).labelsHidden().fixedSize()
            Text("to now").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .help("The timeline shows everything from this moment up to now. The hook keeps a week of history, so up to 7 days back.")
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
    let start: Double, end: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(ticks(start, end), id: \.self) { t in
                    Text(tickLabel(t))
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
    let session: Row, turns: [Turn], agents: [AgentSpan], start: Double, now: Double
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
                    ForEach(ticks(start, now), id: \.self) { t in
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1, height: height).offset(x: x(t, w))
                    }
                    // Subagents: thin lines above Claude's turn, one row per overlap.
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        ForEach(Array(row.enumerated()), id: \.offset) { _, a in
                            agentCapsule(a, row: i, width: w)
                        }
                    }
                    // The centre line: Claude above, you below.
                    Rectangle().fill(Color.primary.opacity(0.16)).frame(width: w, height: 1).offset(y: lineY)
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                        turnBar(t, width: w, lineY: lineY, agentsHeight: agentsHeight)
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
        .onTapGesture(count: 2) { if !session.closed { store.open(session.id) } }
        .help(session.closed ? "This session has been closed" : "Double-click opens the session")
    }

    // These pieces live outside `body` on purpose: inline, the expression was too much for
    // the Swift 6.1 type-checker on CI ("unable to type-check in reasonable time").
    private func agentCapsule(_ a: AgentSpan, row: Int, width w: CGFloat) -> some View {
        let x0 = x(max(a.start, start), w), x1 = x(a.end ?? now, w)
        return Capsule()
            .fill(Color(nsColor: stateColour("working")).opacity(a.background ? 0.3 : 0.5))
            .frame(width: max(3, x1 - x0), height: agentLine)
            .offset(x: x0, y: CGFloat(row) * (agentLine + agentGap))
            .help(agentHelp(a))
    }

    @ViewBuilder
    private func turnBar(_ t: Turn, width w: CGFloat, lineY: CGFloat, agentsHeight: CGFloat) -> some View {
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

    private func agentHelp(_ a: AgentSpan) -> String {
        var text = "\(a.type)"
        if let description = a.description { text += ": \(description)" }
        text += " · \(ago(Int((a.end ?? now) - a.start)))"
        if a.end == nil { text += " · running" }
        if a.background { text += " · background" }
        return text
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
                Text("\(session.closed ? "closed" : "done") · \(ago(session.waiting)) ago")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
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

    /// What a turn was, how long, and when; with the weekday on ranges longer than a day.
    private func help(_ t: Turn) -> String {
        let withDay = now - start > 24 * 3600
        let f = { (d: Double) in
            let date = Date(timeIntervalSince1970: d)
            return withDay ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                           : date.formatted(date: .omitted, time: .shortened)
        }
        return "\(t.title) · \(ago(Int(t.seconds))) (\(f(t.from))–\(f(t.to)))"
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { max(0, min(w, CGFloat((t - start) / (now - start)) * w)) }
}
