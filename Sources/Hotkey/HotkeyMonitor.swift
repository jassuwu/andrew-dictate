import AppKit

@MainActor
final class HotkeyMonitor {
    var onBegin: ((DictationMode) -> Void)?
    var onEnd: ((DictationMode) -> Void)?
    var onCancel: ((DictationMode) -> Void)?
    var onLockBegin: ((DictationMode) -> Void)?
    var onLockEnd: ((DictationMode) -> Void)?
    var onLockCancel: ((DictationMode) -> Void)?
    var onKeyDetected: ((DictationMode) -> Void)?

    private var monitors: [Any] = []
    private let settings: AppSettings
    private var bindings: [DictationMode: HotkeyBinding]
    private var pressedKeyCodes: Set<CGKeyCode> = []
    private var detector = TapLockDetector()

    init(settings: AppSettings = .shared) {
        self.settings = settings
        bindings = Dictionary(
            uniqueKeysWithValues: DictationMode.allCases.map {
                ($0, settings.hotkeyBinding(for: $0))
            }
        )
        installMonitors()
    }

    @discardableResult
    func rebind(
        _ mode: DictationMode,
        to binding: HotkeyBinding
    ) -> Bool {
        guard bindings[mode] != binding else {
            return true
        }
        guard settings.setHotkeyBinding(binding, for: mode) else {
            return false
        }

        perform(detector.cancelForRebind(mode))
        if let oldKeyCode = bindings[mode]?.keyCode {
            pressedKeyCodes.remove(oldKeyCode)
        }
        bindings[mode] = binding
        return true
    }

    private func installMonitors() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                self?.handleKeyDown(event)
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                self?.handleKeyDown(event)
                return event
            }
        ) {
            monitors.append(monitor)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        guard let mode = mode(boundTo: keyCode),
              let binding = bindings[mode],
              let modifierFlag = modifierFlag(for: binding) else {
            return
        }

        if pressedKeyCodes.contains(keyCode) {
            pressedKeyCodes.remove(keyCode)
            perform(
                detector.modifierReleased(
                    mode,
                    at: event.timestamp
                )
            )
        } else if event.modifierFlags.contains(modifierFlag) {
            pressedKeyCodes.insert(keyCode)
            onKeyDetected?(mode)
            perform(
                detector.modifierPressed(
                    mode,
                    at: event.timestamp
                )
            )
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        perform(detector.keyDown(isEscape: event.keyCode == 53))
    }

    private func mode(boundTo keyCode: CGKeyCode) -> DictationMode? {
        DictationMode.allCases.first {
            bindings[$0]?.keyCode == keyCode
        }
    }

    private func modifierFlag(
        for binding: HotkeyBinding
    ) -> NSEvent.ModifierFlags? {
        switch binding.keyCode {
        case HotkeyBinding.fn.keyCode:
            .function
        case HotkeyBinding.rightOption.keyCode,
             HotkeyBinding.leftOption.keyCode:
            .option
        case HotkeyBinding.rightCommand.keyCode,
             HotkeyBinding.leftCommand.keyCode:
            .command
        case HotkeyBinding.rightControl.keyCode,
             HotkeyBinding.leftControl.keyCode:
            .control
        default:
            nil
        }
    }

    private func perform(_ actions: [TapLockDetector.Action]) {
        for action in actions {
            switch action {
            case let .begin(mode):
                onBegin?(mode)
            case let .end(mode):
                onEnd?(mode)
            case let .cancel(mode):
                onCancel?(mode)
            case let .lockBegin(mode):
                onLockBegin?(mode)
            case let .lockEnd(mode):
                onLockEnd?(mode)
            case let .lockCancel(mode):
                onLockCancel?(mode)
            }
        }
    }
}
