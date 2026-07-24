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
    var onModeKeyPressed: ((DictationMode, TimeInterval) -> Bool)?
    var onModeKeyReleased: ((DictationMode, TimeInterval) -> Void)?
    var onEscape: (() -> Bool)?

    private var monitors: [Any] = []
    private let settings: AppSettings
    private var bindings: [DictationMode: HotkeyBinding]
    private var pressedKeyCodes: Set<CGKeyCode> = []
    private var consumedKeyModes: [CGKeyCode: DictationMode] = [:]
    private var detector = TapLockDetector()
    private var provisionalEndTask: Task<Void, Never>?
    private var isDetectionOnly = false

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
            consumedKeyModes.removeValue(forKey: oldKeyCode)
        }
        bindings[mode] = binding
        return true
    }

    func setDetectionOnly(_ enabled: Bool) {
        guard enabled != isDetectionOnly else {
            return
        }

        reset()
        isDetectionOnly = enabled
    }

    func reset() {
        provisionalEndTask?.cancel()
        provisionalEndTask = nil
        pressedKeyCodes.removeAll()
        consumedKeyModes.removeAll()
        perform(detector.reset())
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

        if pressedKeyCodes.contains(keyCode) {
            pressedKeyCodes.remove(keyCode)
            if isDetectionOnly {
                consumedKeyModes.removeValue(forKey: keyCode)
                return
            }
            if let consumedMode = consumedKeyModes.removeValue(
                forKey: keyCode
            ) {
                onModeKeyReleased?(consumedMode, event.timestamp)
                return
            }

            guard let mode = mode(boundTo: keyCode) else {
                return
            }
            perform(
                detector.modifierReleased(
                    mode,
                    at: event.timestamp
                )
            )
            return
        }

        guard let mode = mode(boundTo: keyCode),
              let binding = bindings[mode],
              let modifierFlag = modifierFlag(for: binding),
              event.modifierFlags.contains(modifierFlag) else {
            return
        }

        pressedKeyCodes.insert(keyCode)
        onKeyDetected?(mode)

        guard !isDetectionOnly else {
            return
        }

        if onModeKeyPressed?(mode, event.timestamp) == true {
            consumedKeyModes[keyCode] = mode
            _ = detector.keyDown(isEscape: false)
            return
        }

        perform(
            detector.modifierPressed(
                mode,
                at: event.timestamp
            )
        )
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !isDetectionOnly else {
            return
        }

        let isEscape = event.keyCode == 53
        if isEscape, onEscape?() == true {
            _ = detector.keyDown(isEscape: false)
            return
        }
        perform(detector.keyDown(isEscape: isEscape))
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
            case .provisionalEnd:
                scheduleProvisionalEnd()
            case let .end(mode):
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onEnd?(mode)
            case let .cancel(mode):
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onCancel?(mode)
            case let .lockBegin(mode):
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onLockBegin?(mode)
            case let .lockEnd(mode):
                onLockEnd?(mode)
            case let .lockCancel(mode):
                onLockCancel?(mode)
            }
        }
    }

    private func scheduleProvisionalEnd() {
        provisionalEndTask?.cancel()
        provisionalEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(TapLockDetector.maximumTapGap)
            )
            guard !Task.isCancelled, let self else {
                return
            }
            self.provisionalEndTask = nil
            self.perform(
                self.detector.provisionalEndWindowExpired()
            )
        }
    }
}
