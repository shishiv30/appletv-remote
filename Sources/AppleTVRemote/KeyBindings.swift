import AppKit
import Combine

// MARK: - Actions

/// Everything a hardware key can be bound to in the remote pane.
enum RemoteAction: String, CaseIterable, Codable, Identifiable {
    case up, down, left, right
    case select, menu, home
    case playPause
    case volumeUp, volumeDown
    case swipeUp, swipeDown, swipeLeft, swipeRight
    case showApps
    case toggleTrackpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up:             return "Up"
        case .down:           return "Down"
        case .left:           return "Left"
        case .right:          return "Right"
        case .select:         return "Select (hold for long-press)"
        case .menu:           return "Menu / Back (hold for long-press)"
        case .home:           return "Home (hold for Control Center)"
        case .playPause:      return "Play / Pause"
        case .volumeUp:       return "Volume up"
        case .volumeDown:     return "Volume down"
        case .swipeUp:        return "Swipe up"
        case .swipeDown:      return "Swipe down"
        case .swipeLeft:      return "Swipe left"
        case .swipeRight:     return "Swipe right"
        case .showApps:       return "Apps grid"
        case .toggleTrackpad: return "Trackpad mode on / off"
        }
    }

    static let groups: [(title: String, actions: [RemoteAction])] = [
        ("Navigation",   [.up, .down, .left, .right, .select, .menu]),
        ("Playback",     [.playPause]),
        ("Volume",       [.volumeUp, .volumeDown]),
        ("Touch swipe",  [.swipeUp, .swipeDown, .swipeLeft, .swipeRight]),
        ("System",       [.home, .showApps, .toggleTrackpad]),
    ]
}

// MARK: - Key chord

/// A key plus modifiers. Matched on the physical key code, so a binding stays
/// on the same key across keyboard layouts. `label` is only for display and is
/// ignored by `==` / `hash`.
struct KeyChord: Codable, Hashable {
    static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    let keyCode: UInt16
    let modifiers: UInt
    let label: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
        self.label = label
    }

    init(event: NSEvent) {
        let code = event.keyCode
        self.init(keyCode: code,
                  modifiers: event.modifierFlags,
                  label: Self.specialKeyNames[code]
                      ?? event.charactersIgnoringModifiers?.uppercased()
                      ?? "Key \(code)")
    }

    static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    /// e.g. "⌃H", "⇧↑", "Space".
    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }

    static let specialKeyNames: [UInt16: String] = [
        126: "↑", 125: "↓", 123: "←", 124: "→",
        36: "Return", 76: "Enter", 53: "Esc", 49: "Space", 51: "Delete",
        117: "Fwd Delete", 116: "Page Up", 121: "Page Down",
        115: "Home", 119: "End", 48: "Tab",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

// MARK: - Store

/// User-editable key bindings, persisted in UserDefaults. `KeyCatcherView`
/// resolves every keyDown through `action(for:)`.
@MainActor
final class KeyBindingStore: ObservableObject {
    static let shared = KeyBindingStore()
    static let defaultsKey = "com.adhir.appletv-remote.keyBindings"

    @Published private(set) var bindings: [RemoteAction: [KeyChord]]
    private var lookup: [KeyChord: RemoteAction] = [:]
    private let defaults: UserDefaults

    static let defaultBindings: [RemoteAction: [KeyChord]] = [
        .up:        [KeyChord(keyCode: 126, label: "↑")],
        .down:      [KeyChord(keyCode: 125, label: "↓")],
        .left:      [KeyChord(keyCode: 123, label: "←")],
        .right:     [KeyChord(keyCode: 124, label: "→")],
        .select:    [KeyChord(keyCode: 36, label: "Return"), KeyChord(keyCode: 76, label: "Enter")],
        .menu:      [KeyChord(keyCode: 51, label: "Delete")],
        .home:      [KeyChord(keyCode: 53, label: "Esc")],
        .playPause: [KeyChord(keyCode: 49, label: "Space")],
        .volumeUp:   [KeyChord(keyCode: 24, label: "=")],
        .volumeDown: [KeyChord(keyCode: 27, label: "-")],
        .swipeUp:    [KeyChord(keyCode: 126, modifiers: .shift, label: "↑")],
        .swipeDown:  [KeyChord(keyCode: 125, modifiers: .shift, label: "↓")],
        .swipeLeft:  [KeyChord(keyCode: 123, modifiers: .shift, label: "←")],
        .swipeRight: [KeyChord(keyCode: 124, modifiers: .shift, label: "→")],
        .showApps:       [KeyChord(keyCode: 0, label: "A")],
        .toggleTrackpad: [KeyChord(keyCode: 42, label: "\\")],
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = Self.defaultBindings
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: [KeyChord]].self, from: data) {
            // Saved entries win; actions added in a later version keep their defaults.
            for (raw, chords) in saved {
                if let action = RemoteAction(rawValue: raw) { loaded[action] = chords }
            }
        }
        bindings = loaded
        rebuildLookup()
    }

    func action(for chord: KeyChord) -> RemoteAction? { lookup[chord] }

    func action(for event: NSEvent) -> RemoteAction? { lookup[KeyChord(event: event)] }

    func chords(for action: RemoteAction) -> [KeyChord] { bindings[action] ?? [] }

    /// Bind `chord` to `action`. A chord drives one action only, so it is
    /// removed from whichever action held it; that action is returned.
    @discardableResult
    func add(_ chord: KeyChord, to action: RemoteAction) -> RemoteAction? {
        let previous = lookup[chord]
        if previous == action { return nil }
        if let previous { bindings[previous]?.removeAll { $0 == chord } }
        bindings[action, default: []].append(chord)
        commit()
        return previous
    }

    func remove(_ chord: KeyChord, from action: RemoteAction) {
        bindings[action]?.removeAll { $0 == chord }
        commit()
    }

    func resetToDefaults() {
        bindings = Self.defaultBindings
        defaults.removeObject(forKey: Self.defaultsKey)
        rebuildLookup()
    }

    private func commit() {
        rebuildLookup()
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func rebuildLookup() {
        lookup.removeAll()
        for (action, chords) in bindings {
            for chord in chords { lookup[chord] = action }
        }
    }
}
