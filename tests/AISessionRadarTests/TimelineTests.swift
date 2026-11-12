import Foundation
import Testing

@testable import AISessionRadar

struct TimelineTests {
    // A fixed mid-June moment, away from any daylight-saving switch: 2026-06-15 12:34 UTC.
    let june = 1_781_526_840.0

    @Test("the 1, 3 and 8 hour presets keep their tick spacing")
    func presets() {
        #expect(tickStep(3600) == 900)
        #expect(tickStep(3 * 3600) == 1800)
        #expect(tickStep(8 * 3600) == 3600)
    }

    @Test("every range from a quarter of an hour to a week keeps the axis at eight labels or fewer")
    func labelCount() {
        for quarters in 1...(7 * 24 * 4) {
            let span = Double(quarters) * 900
            let count = ticks(june - span, june).count
            #expect(count <= 8, "\(span / 3600) hours: \(count) labels")
            if span >= 3600 { #expect(count >= 2, "\(span / 3600) hours: \(count) labels") }
        }
    }

    @Test("ticks fall on whole local wall-clock hours, every few hours from midnight",
          arguments: [8.0, 12, 48, 96, 168])
    func localAlignment(hours: Double) {
        let stepHours = Int(tickStep(hours * 3600) / 3600)
        for t in ticks(june - hours * 3600, june) {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
            #expect(c.minute == 0)
            #expect((c.hour ?? -1) % stepHours == 0)
        }
    }

    @Test("across the switch to winter time, daily ticks stay at midnight and 6-hourly ones on the clock")
    func daylightSaving() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        let end = 1_793_188_800.0  // 2026-10-28 12:00 UTC; clocks went back on 25 October
        for (span, step) in [(7 * 24 * 3600.0, 24), (2 * 24 * 3600.0 + 4 * 3600, 6)] {
            let t = ticks(end - span, end, calendar: cal)
            #expect(!t.isEmpty)
            for tick in t {
                let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: tick))
                #expect(c.minute == 0 && (c.hour ?? -1) % step == 0)
            }
        }
    }

    @Test("a custom start stays within the week the hook keeps and at least a quarter of an hour back")
    func customStartBounds() {
        let now = june
        #expect(customStart(now - 3 * 86400, now: now) == now - 3 * 86400)
        #expect(customStart(now - 30 * 86400, now: now) == now - timelineMaxBack)
        #expect(customStart(now + 3600, now: now) == now - timelineMinSpan)
        let unset = customStart(0, now: now)
        #expect(unset <= now - 24 * 3600 && unset > now - 25 * 3600)
    }
}
