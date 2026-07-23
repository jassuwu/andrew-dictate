import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var preRollEnabled: Bool {
        didSet {
            guard preRollEnabled != oldValue else {
                return
            }
            userDefaults.set(preRollEnabled, forKey: Self.preRollKey)
        }
    }

    @Published var dictationHotkey: HotkeyBinding {
        didSet {
            guard dictationHotkey != oldValue else {
                return
            }
            userDefaults.setHotkeyBinding(dictationHotkey, for: .dictation)
        }
    }

    @Published var commandHotkey: HotkeyBinding {
        didSet {
            guard commandHotkey != oldValue else {
                return
            }
            userDefaults.setHotkeyBinding(commandHotkey, for: .command)
        }
    }

    private static let preRollKey = "AndrewDictate.preRollEnabled"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        preRollEnabled = userDefaults.bool(forKey: Self.preRollKey)
        dictationHotkey = userDefaults.hotkeyBinding(for: .dictation)
        commandHotkey = userDefaults.hotkeyBinding(for: .command)
    }

    func hotkeyBinding(for mode: DictationMode) -> HotkeyBinding {
        switch mode {
        case .dictation:
            dictationHotkey
        case .command:
            commandHotkey
        }
    }

    func setHotkeyBinding(
        _ binding: HotkeyBinding,
        for mode: DictationMode
    ) {
        switch mode {
        case .dictation:
            dictationHotkey = binding
        case .command:
            commandHotkey = binding
        }
    }
}
