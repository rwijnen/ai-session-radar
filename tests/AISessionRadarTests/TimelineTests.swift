import Foundation
import Testing

@testable import AISessionRadar

struct TimelineTests {
    @Test("the 1, 3 and 8 hour presets keep their tick spacing")
    func presets() {
        #expect(tickStep(1) == 900)
        #expect(tickStep(3) == 1800)
        #expect(tickStep(8) == 3600)
    }

    @Test("every range up to a day keeps the axis at eight labels or fewer", arguments: 1...timelineMaxHours)
    func labelCount(hours: Int) {
        // A fixed mid-June moment, away from any daylight-saving switch.
        let now = 1_781_526_840.0  // 2026-06-15 12:34 UTC
        let t = ticks(now - Double(hours) * 3600, now, hours)
        #expect(!t.isEmpty)
        #expect(t.count <= 8)
    }

    @Test("ticks fall on whole local hours, every 2 or 3 hours from midnight on long ranges", arguments: [8, 12, 24])
    func localAlignment(hours: Int) {
        let now = 1_781_526_840.0
        let stepHours = Int(tickStep(hours) / 3600)
        for t in ticks(now - Double(hours) * 3600, now, hours) {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
            #expect(c.minute == 0)
            #expect((c.hour ?? -1) % stepHours == 0)
        }
    }
}
