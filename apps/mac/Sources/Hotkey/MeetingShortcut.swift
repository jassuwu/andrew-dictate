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

    /// Why settings will not take a shortcut, in the few words the row says.
    enum Refusal: Equatable, Sendable {
        case needsAModifier
        case includesTheDictationKey(HotkeyBinding)

        var message: String {
            switch self {
            case .needsAModifier:
                "needs ⌃, ⌥ or ⌘ held with it"
            case .includesTheDictationKey(let key):
                "includes your dictation key, \(key.displayName)"
            }
        }
    }

    func refusal(againstDictationKey key: HotkeyBinding) -> Refusal? {
        guard !modifiers.isDisjoint(with: [.control, .option, .command]) else {
            return .needsAModifier
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
