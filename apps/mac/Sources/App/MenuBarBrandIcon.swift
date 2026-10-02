import AppKit

@MainActor
enum MenuBarBrandIcon {
    static func image(
        for state: DictationCoordinator.State,
        needsAttention: Bool = false,
        isRecordingMeeting: Bool = false
    ) -> NSImage {
        // today's inputs, as the badge's looks. the coordinator tells a
        // meeting from a take, so a recording meeting wears the gold rim
        // where it used to borrow dictation's dot; the badge is the
        // persistent indicator the hud deliberately is not (ADR 0040). a
        // call nobody records, a meeting getting ready and a meeting's
        // problem are drawn but not asked for yet: they arrive with the
        // meeting's own states.
        //
        // transcribing is not dictating on purpose. the lamp's cool phase
        // owns the wait and the menu already says "writing it out…" (ADR
        // 0017); a narrower template glyph here only shoved the clock
        // sideways and back, seventy times a day.
        image(
            for: BadgeLook(
                needsSetup: needsAttention,
                isDictating: state == .recording,
                meeting: isRecordingMeeting ? .recording : .none
            )
        )
    }

    /// the actual brand badge, full color, wearing `look`'s mark.
    /// non-template by design: the logo is the logo, everywhere (user
    /// directive).
    static func image(for look: BadgeLook) -> NSImage {
        guard let base = NSImage(named: "MenuBarBadge") else {
            return fallback(for: look)
        }
        base.size = BadgeMarks.size
        base.isTemplate = false

        let image = BadgeMarks.image(for: look, on: base)
        if let description = accessibilityDescription(for: look) {
            image.accessibilityDescription = description
        }
        return image
    }

    /// what VoiceOver hears for the image itself; the menu bar item's
    /// label says the state in words on top of this. the bare badge keeps
    /// the asset's own.
    private static func accessibilityDescription(
        for look: BadgeLook
    ) -> String? {
        switch look {
        case .idle: nil
        case .dictating: "Andrew Dictate recording"
        case .callNotRecorded: "Andrew Dictate, a call is on"
        case .gettingReady: "Andrew Dictate getting ready to record a meeting"
        case .recordingMeeting: "Andrew Dictate recording a meeting"
        case .meetingProblem: "Andrew Dictate has a problem with the meeting"
        case .needsSetup: "Andrew Dictate needs setup"
        }
    }

    /// only a build with a broken asset catalog lands here: a system glyph,
    /// so the item is never blank.
    private static func fallback(for look: BadgeLook) -> NSImage {
        let warns = look == .needsSetup || look == .meetingProblem
        let fallback = NSImage(
            systemSymbolName: warns
                ? "exclamationmark.triangle.fill"
                : "mic.fill",
            accessibilityDescription: accessibilityDescription(for: look)
                ?? "Andrew Dictate"
        ) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
