import AppKit

/// the badge is the persistent indicator the hud deliberately is not (ADR
/// 0040): it wears what `DictationCoordinator.badgeLook` says, a take, a
/// meeting's phase, a call nobody records or a setup gap.
@MainActor
enum MenuBarBrandIcon {
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
        // worn while a meeting gets ready and while one is written out:
        // the menu bar item's label says which.
        case .gettingReady: "Andrew Dictate busy with a meeting"
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
