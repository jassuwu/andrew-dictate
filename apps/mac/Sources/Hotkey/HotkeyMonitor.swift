import AppKit

@MainActor
final class HotkeyMonitor {
    var onBegin: (() -> Void)?
    /// the ends carry the key event's own timestamp (seconds since boot,
    /// `NSEvent.timestamp`), so key-up can be when the finger lifted rather
    /// than when the main thread got round to hearing it.
    var onEnd: ((TimeInterval?) -> Void)?
    var onCancel: (() -> Void)?
    /// another key during a hold, with that key's own timestamp.
    var onChord: ((TimeInterval?) -> Void)?
    var onLockBegin: (() -> Void)?
    var onLockEnd: ((TimeInterval?) -> Void)?
    var onLockCancel: (() -> Void)?
    var onKeyDetected: (() -> Void)?
    var onEscape: (() -> Bool)?

    private var monitors: [Any] = []
    private let settings: AppSettings
    private var binding: HotkeyBinding
    private var pressedKeyCodes: Set<CGKeyCode> = []
    private var detector = TapLockDetector()
    private var provisionalEndTask: Task<Void, Never>?
    private var isDetectionOnly = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        binding = settings.dictationHotkey
        installMonitors()
    }

    @discardableResult
    func rebind(to newBinding: HotkeyBinding) -> Bool {
        guard binding != newBinding else {
            return true
        }
        guard settings.setHotkeyBinding(newBinding) else {
            return false
        }

        perform(detector.cancelForRebind())
        pressedKeyCodes.remove(binding.keyCode)
        binding = newBinding
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
        perform(detector.reset())
    }

    /// a global monitor added while the app was untrusted never starts
    /// hearing keys, so granting accessibility has to build new ones or fn
    /// stays dead until the next launch. `binding` and `isDetectionOnly` are
    /// deliberately untouched: a custom key and onboarding's detection-only
    /// mode outlive the swap.
    func reinstall() {
        reset()
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        installMonitors()
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
                return
            }

            guard keyCode == binding.keyCode else {
                return
            }
            perform(
                detector.modifierReleased(at: event.timestamp),
                at: event.timestamp
            )
            return
        }

        guard keyCode == binding.keyCode,
              let modifierFlag = modifierFlag(for: binding),
              event.modifierFlags.contains(modifierFlag) else {
            return
        }

        pressedKeyCodes.insert(keyCode)
        onKeyDetected?()

        guard !isDetectionOnly else {
            return
        }

        perform(
            detector.modifierPressed(at: event.timestamp),
            at: event.timestamp
        )
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !isDetectionOnly else {
            return
        }

        let isEscape = event.keyCode == 53
        if isEscape, onEscape?() == true {
            // the coordinator already did the cancelling, so all that is
            // left is clearing the detector. `keyDown(isEscape: false)`
            // cannot do it: it deliberately no-ops while locked — that is
            // what keeps ordinary typing from ending a locked capture — and
            // would leave the next hold swallowed by a still-locked state.
            _ = detector.reset()
            return
        }
        perform(
            detector.keyDown(isEscape: isEscape),
            at: event.timestamp
        )
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

    /// `timestamp` is the key event behind these actions, when there is one:
    /// a provisional end that timed out, a reset or a rebind has none.
    private func perform(
        _ actions: [TapLockDetector.Action],
        at timestamp: TimeInterval? = nil
    ) {
        for action in actions {
            switch action {
            case .begin:
                onBegin?()
            case .provisionalEnd:
                scheduleProvisionalEnd()
            case .end:
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onEnd?(timestamp)
            case .cancel:
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onCancel?()
            case .chord:
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onChord?(timestamp)
            case .lockBegin:
                provisionalEndTask?.cancel()
                provisionalEndTask = nil
                onLockBegin?()
            case .lockEnd:
                onLockEnd?(timestamp)
            case .lockCancel:
                onLockCancel?()
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
