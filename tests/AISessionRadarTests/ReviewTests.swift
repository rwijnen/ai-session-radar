import Foundation
import Testing

@testable import AISessionRadar

/// Review with Claude: which folder a PR's review session opens in, and when the button is off.
struct ReviewTests {
    let found = ["ValanticDMC/Miele": "/repos/Miele"]
    let exists: (String) -> Bool = { $0 != "/gone" }

    @Test("a checkout found from sessions is used when none is set")
    func foundCheckout() {
        let c = reviewCheckout("ValanticDMC/Miele", set: [:], found: found, isFolder: exists)
        #expect(c == ReviewCheckout(folder: "/repos/Miele", fromSetting: false, exists: true))
        #expect(c.usable)
    }

    @Test("the folder set in Settings wins, whatever the case of the repo name")
    func setWins() {
        let c = reviewCheckout("valanticdmc/miele", set: ["ValanticDMC/Miele": "/work/Miele"], found: found, isFolder: exists)
        #expect(c == ReviewCheckout(folder: "/work/Miele", fromSetting: true, exists: true))
    }

    @Test("an empty setting falls back to the found checkout")
    func emptySetting() {
        let c = reviewCheckout("ValanticDMC/Miele", set: ["ValanticDMC/Miele": ""], found: found, isFolder: exists)
        #expect(c.folder == "/repos/Miele" && !c.fromSetting)
    }

    @Test("no checkout, or one that no longer exists, turns the button off")
    func unusable() {
        let none = reviewCheckout("acme/app", set: [:], found: found, isFolder: exists)
        #expect(none.folder == nil && !none.usable)
        let gone = reviewCheckout("acme/app", set: ["acme/app": "/gone"], found: [:], isFolder: exists)
        #expect(gone.folder == "/gone" && gone.fromSetting && !gone.usable)
    }
}
