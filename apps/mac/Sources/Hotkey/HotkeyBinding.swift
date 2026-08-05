import CoreGraphics
import Foundation

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

    static let supported: [HotkeyBinding] = [
        .fn,
        .rightOption,
        .leftOption,
        .rightCommand,
        .leftCommand,
        .rightControl,
        .leftControl,
    ]
}

extension UserDefaults {
    func hotkeyBinding() -> HotkeyBinding {
        guard let data = data(
            forKey: "AndrewDictate.hotkey.dictation"
        ),
              let binding = try? JSONDecoder().decode(
                  HotkeyBinding.self,
                  from: data
              ) else {
            return .dictation
        }

        return binding
    }

    func setHotkeyBinding(_ binding: HotkeyBinding) {
        guard let data = try? JSONEncoder().encode(binding) else {
            return
        }

        set(data, forKey: "AndrewDictate.hotkey.dictation")
    }
}
