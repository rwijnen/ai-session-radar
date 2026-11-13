import AppKit
import Carbon.HIToolbox
import Combine

/// A key with its modifiers, in the form Carbon's hot-key API takes them.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier bits: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32
    /// The key's label on the layout it was recorded on: "R", "Space", "F5".
    var key: String

    /// ⌃⌥⌘R, R for radar. Three modifiers, so it rarely clashes with another app's own shortcut.
    static let standard = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey), key: "R")

    /// Written the way macOS menus write shortcuts: ⌃⌥⇧⌘, then the key.
    var display: String {
        let order: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return order.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// The combo of a key press, or nil when it is no use as a shortcut from any app: it needs
    /// ⌘, ⌃ or ⌥, except a function key, which works alone. `characters` is what the key types
    /// without modifiers (`NSEvent.characters(byApplyingModifiers: [])`).
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        let functionKey = Self.functionKeys[Int(keyCode)]
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 || functionKey != nil else { return nil }
        let typed = characters?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).uppercased()
        guard let label = functionKey ?? Self.namedKeys[Int(keyCode)] ?? typed, !label.isEmpty else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: m, key: label)
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Keys that type nothing visible, labelled as macOS menus label them.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

/// The keyboard shortcut that opens the board from any app.
///
/// Carbon's hot-key API is still how a Mac app takes a system-wide shortcut: it needs no
/// Accessibility permission, and the key press goes to this app only, so the app in front never
/// sees it. The shortcut is registered as exclusive, so macOS refuses it when another app already
/// holds the same keys, and Settings says so instead of two apps reacting to one press.
final class GlobalShortcut: ObservableObject {
    /// Set when the shortcut is switched on but macOS did not accept it.
    @Published private(set) var problem: String?
    /// Runs on the main thread when the shortcut is pressed.
    var action: () -> Void = {}
    /// While Settings records a new shortcut, the current one is off, so pressing it can be recorded.
    var paused = false {
        didSet { if paused != oldValue { apply(preferences.shortcutEnabled, preferences.shortcut) } }
    }

    private static let signature: OSType = 0x5241_4452  // 'RADR'
    private let preferences: Preferences
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var watcher: AnyCancellable?

    init(preferences: Preferences) { self.preferences = preferences }

    /// Registers the shortcut from the preferences, and again whenever they change.
    func start() {
        installHandler()
        // @Published sends before the property changes, so take the values from the publisher.
        watcher = preferences.$shortcutEnabled.combineLatest(preferences.$shortcut)
            .sink { [weak self] on, combo in self?.apply(on, combo) }
    }

    private func apply(_ on: Bool, _ combo: KeyCombo) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard on, !paused else { problem = nil; return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr {
            hotKey = ref
            problem = nil
        } else {
            problem = "macOS did not accept \(combo.display): another app already uses it. Record another shortcut."
            Log.app.error("RegisterEventHotKey \(combo.display, privacy: .public) failed: \(status)")
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback cannot capture; it finds this object through the user-data pointer.
        // The app keeps the shortcut for its whole life, so the unretained pointer stays valid.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
