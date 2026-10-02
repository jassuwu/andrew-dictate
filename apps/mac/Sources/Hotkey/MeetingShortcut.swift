import Foundation

/// An optional global shortcut that starts a meeting, and stops it while one
/// records. Not a dictation key: that one is a lone modifier held and let
/// go, and this is a chord pressed once, so it is its own small thing with
/// its own stored value.
struct MeetingShortcut: Codable, Hashable, Sendable {
    /// What is held with the key. Shift counts but never stands alone: a
    /// shortcut with only shift in it would fire on every capital letter.
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    let keyCode: UInt16
    let modifiers: Modifiers
    /// what the key said when it was recorded, kept like the dictation key
    /// keeps its display name: the layout can change, the row should not.
    let keyName: String

    static let escapeKeyCode: UInt16 = 53

    /// What to call a key that was just pressed: its character, upper-cased,
    /// or its own word or glyph for the keys that have no character worth
    /// showing.
    static func keyName(forKeyCode keyCode: UInt16, characters: String) -> String {
        specialKeyNames[keyCode] ?? characters.uppercased()
    }

    /// virtual key codes, which do not change with the layout.
    private static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "space", 51: "⌫", 53: "esc", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]

    /// the chip in settings: modifiers in the order the mac writes them,
    /// then the key.
    var displayName: String {
        let held = [
            (Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        return held.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }

    /// Why settings will not take a shortcut, in the few words the row says.
    enum Refusal: Equatable, Sendable {
        case needsAModifier
        case isEscape
        case includesTheDictationKey(HotkeyBinding)

        var message: String {
            switch self {
            case .needsAModifier:
                "needs ⌃, ⌥ or ⌘ held with it"
            case .isEscape:
                "esc cancels a dictation"
            case .includesTheDictationKey(let key):
                "includes your dictation key, \(key.displayName)"
            }
        }
    }

    func refusal(againstDictationKey key: HotkeyBinding) -> Refusal? {
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else {
            return .needsAModifier
        }
        guard keyCode != Self.escapeKeyCode else {
            return .isEscape
        }
        if let held = Self.modifier(of: key), modifiers.contains(held) {
            return .includesTheDictationKey(key)
        }
        return nil
    }

    /// The modifier a dictation key is, for a shortcut that holds it. Left
    /// and right are one modifier here. fn is none: a shortcut cannot hold
    /// it, so it never clashes.
    private static func modifier(of key: HotkeyBinding) -> Modifiers? {
        switch key.keyCode {
        case HotkeyBinding.leftOption.keyCode, HotkeyBinding.rightOption.keyCode:
            .option
        case HotkeyBinding.leftCommand.keyCode, HotkeyBinding.rightCommand.keyCode:
            .command
        case HotkeyBinding.leftControl.keyCode, HotkeyBinding.rightControl.keyCode:
            .control
        default:
            nil
        }
    }

    /// What a press of the shortcut does.
    enum Press: Equatable, Sendable {
        case start
        case stop
    }

    static func press(whileRecording isRecording: Bool) -> Press {
        isRecording ? .stop : .start
    }
}
