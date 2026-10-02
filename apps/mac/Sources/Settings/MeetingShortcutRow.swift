import AppKit
import SwiftUI

/// the meeting shortcut in settings: click the chip, press a combination,
/// done. the dictation key is a pick from a short list of lone modifiers, so
/// there was nothing here to reuse that records a chord.
struct MeetingShortcutRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var coordinator: DictationCoordinator

    @State private var isListening = false
    @State private var monitor: Any?
    /// why the last combination was not taken, until the next try.
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 16) {
                SettingsRowLabel(
                    "meeting shortcut",
                    explanation: "starts a meeting, and stops the one that records. needs ⌃ or ⌘."
                )

                Spacer(minLength: 8)

                Button(action: toggleListening) {
                    KeyChip(chipText, isActive: isListening)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("meeting shortcut")
                .accessibilityValue(chipText)
                .accessibilityHint("press to choose a new one")

                if settings.meetingShortcut != nil {
                    Button("clear", action: clear)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)
                }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(BrandUI.attention)
            }
        }
        // the app going to the background ends it: no key would reach the
        // monitor, and the old shortcut should not stay let go.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification)
        ) { _ in
            stopListening()
        }
        .onDisappear(perform: stopListening)
    }

    private var chipText: String {
        if isListening {
            return "press a shortcut…"
        }
        return settings.meetingShortcut?.displayName ?? "not set"
    }

    /// a refusal, or another app holding what was chosen: the row says it
    /// in a few words and the shortcut stays what it was.
    private var note: String? {
        if let refusal {
            return refusal
        }
        if settings.meetingShortcut != nil, coordinator.meetingShortcutIsTaken {
            return "another app already uses that."
        }
        return nil
    }

    private func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        refusal = nil
        isListening = true
        coordinator.holdMeetingShortcut(true)
        // every key goes to this row until one is taken, so nothing typed
        // meanwhile reaches the pane behind it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            heard(event)
            return nil
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard isListening else {
            return
        }
        isListening = false
        coordinator.holdMeetingShortcut(false)
    }

    private func heard(_ event: NSEvent) {
        guard !event.isARepeat else {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // esc on its own is how you leave without choosing.
        if event.keyCode == MeetingShortcut.escapeKeyCode,
           flags.isDisjoint(with: [.control, .option, .command, .shift]) {
            stopListening()
            return
        }

        var modifiers: MeetingShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let shortcut = MeetingShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyName: MeetingShortcut.keyName(
                forKeyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? ""))

        if let reason = settings.setMeetingShortcut(shortcut) {
            // still listening: the next combination may be fine.
            refusal = reason.message
            return
        }
        refusal = nil
        stopListening()
    }

    private func clear() {
        stopListening()
        refusal = nil
        settings.setMeetingShortcut(nil)
    }
}
