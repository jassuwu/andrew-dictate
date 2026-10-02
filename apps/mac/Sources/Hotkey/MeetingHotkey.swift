import Carbon
import Foundation
import os

/// The meeting shortcut, registered with the system as a global hot key.
///
/// Not the dictation key's mechanism on purpose. That one listens to every
/// key through an event monitor, which is the accessibility permission, and
/// someone who only records meetings has not been asked for it. A registered
/// hot key asks for nothing: the system says when this one combination is
/// pressed, hears no other key, and takes the press, so the dictation key's
/// monitor is not shown it.
@MainActor
final class MeetingHotkey {
    /// the shortcut was pressed.
    var onPress: (() -> Void)?

    /// What is registered, or nil. Setting it replaces the old one.
    var shortcut: MeetingShortcut? {
        didSet { apply() }
    }

    /// While the settings row listens for a new combination, the old one
    /// must not fire: pressing it again to keep it would start a meeting.
    var isHeld = false {
        didSet { apply() }
    }

    /// Another app holds the combination, so the system would not give it.
    /// The setting stays; the row says so.
    private(set) var isTaken = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private static let logger = Logger(
        subsystem: AppIdentity.loggingSubsystem, category: "meeting-hotkey")
    /// 'ADMH': ours among the hot keys of this process.
    private static let signature: OSType = 0x41_44_4D_48

    private func apply() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        isTaken = false
        guard let shortcut, !isHeld else { return }

        installHandlerOnce()
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &registered)
        guard status == noErr, let registered else {
            // -9878 is another app already holding it.
            isTaken = true
            Self.logger.error(
                "the meeting shortcut \(shortcut.displayName, privacy: .public) could not be registered: \(status)")
            return
        }
        hotKey = registered
        Self.logger.info("the meeting shortcut \(shortcut.displayName, privacy: .public) is registered")
    }

    private func installHandlerOnce() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else {
                    return OSStatus(eventNotHandledErr)
                }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == MeetingHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkey = Unmanaged<MeetingHotkey>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in hotkey.onPress?() }
                return noErr
            },
            1, &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
        if status != noErr {
            Self.logger.error("the hot key handler could not be installed: \(status)")
        }
    }
}

extension MeetingShortcut.Modifiers {
    /// the flags `RegisterEventHotKey` wants.
    var carbonFlags: UInt32 {
        var flags = 0
        if contains(.control) { flags |= controlKey }
        if contains(.option) { flags |= optionKey }
        if contains(.shift) { flags |= shiftKey }
        if contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }
}
