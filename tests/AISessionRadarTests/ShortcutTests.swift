import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import AISessionRadar

/// The keyboard shortcut that opens the board: which key presses can become one, how they read,
/// and that the recorded one survives a restart.
struct ShortcutTests {
    @Test("the built-in shortcut is ⌃⌥⌘R")
    func standard() {
        #expect(KeyCombo.standard.display == "⌃⌥⌘R")
        #expect(KeyCombo.standard.keyCode == UInt32(kVK_ANSI_R))
    }

    @Test("modifiers read in the macOS menu order ⌃⌥⇧⌘")
    func menuOrder() throws {
        let combo = try #require(KeyCombo(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift, .option, .control], characters: "k"))
        #expect(combo.display == "⌃⌥⇧⌘K")
        #expect(combo.modifiers == UInt32(cmdKey | shiftKey | optionKey | controlKey))
    }

    @Test("a shortcut needs ⌘, ⌃ or ⌥", arguments: [NSEvent.ModifierFlags(), [.shift]])
    func needsModifier(_ flags: NSEvent.ModifierFlags) {
        #expect(KeyCombo(keyCode: UInt16(kVK_ANSI_A), flags: flags, characters: "a") == nil)
    }

    @Test("a function key works alone")
    func functionKey() {
        #expect(KeyCombo(keyCode: UInt16(kVK_F5), flags: [], characters: "\u{F708}")?.display == "F5")
    }

    @Test("keys that type nothing visible get their macOS names")
    func namedKeys() {
        #expect(KeyCombo(keyCode: UInt16(kVK_Space), flags: [.option], characters: " ")?.display == "⌥Space")
        #expect(KeyCombo(keyCode: UInt16(kVK_UpArrow), flags: [.control, .command], characters: "\u{F700}")?.display == "⌃⌘↑")
    }

    @Test("Preferences keep the recorded shortcut and the on/off switch")
    func persists() throws {
        let suite = "ShortcutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = Preferences(defaults: defaults)
        #expect(first.shortcutEnabled)
        #expect(first.shortcut == .standard)

        let combo = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
        first.shortcut = combo
        first.shortcutEnabled = false

        let second = Preferences(defaults: defaults)
        #expect(second.shortcut == combo)
        #expect(!second.shortcutEnabled)
    }
}
