import CoreGraphics
import Foundation

enum DictationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case dictation
    case command

    var other: Self {
        switch self {
        case .dictation:
            .command
        case .command:
            .dictation
        }
    }
}

struct HotkeyBinding: Codable, Hashable, Identifiable, Sendable {
    let keyCode: CGKeyCode
    let displayName: String

    var id: CGKeyCode {
        keyCode
    }

    static let fn = HotkeyBinding(keyCode: 63, displayName: "fn")
    static let rightOption = HotkeyBinding(
        keyCode: 61,
        displayName: "right ⌥"
    )
    static let leftOption = HotkeyBinding(
        keyCode: 58,
        displayName: "left ⌥"
    )
    static let rightCommand = HotkeyBinding(
        keyCode: 54,
        displayName: "right ⌘"
    )
    static let leftCommand = HotkeyBinding(
        keyCode: 55,
        displayName: "left ⌘"
    )
    static let rightControl = HotkeyBinding(
        keyCode: 62,
        displayName: "right ⌃"
    )
    static let leftControl = HotkeyBinding(
        keyCode: 59,
        displayName: "left ⌃"
    )

    static let dictation = fn
    static let command = rightOption

    static let supported: [HotkeyBinding] = [
        .fn,
        .rightOption,
        .leftOption,
        .rightCommand,
        .leftCommand,
        .rightControl,
        .leftControl,
    ]

    static func defaultBinding(for mode: DictationMode) -> HotkeyBinding {
        switch mode {
        case .dictation:
            .dictation
        case .command:
            .command
        }
    }
}

extension UserDefaults {
    func hotkeyBinding(for mode: DictationMode) -> HotkeyBinding {
        guard let data = data(forKey: hotkeyKey(for: mode)),
              let binding = try? JSONDecoder().decode(
                  HotkeyBinding.self,
                  from: data
              ) else {
            return .defaultBinding(for: mode)
        }

        return binding
    }

    func setHotkeyBinding(
        _ binding: HotkeyBinding,
        for mode: DictationMode
    ) {
        guard let data = try? JSONEncoder().encode(binding) else {
            return
        }

        set(data, forKey: hotkeyKey(for: mode))
    }

    private func hotkeyKey(for mode: DictationMode) -> String {
        "AndrewDictate.hotkey.\(mode.rawValue)"
    }
}
