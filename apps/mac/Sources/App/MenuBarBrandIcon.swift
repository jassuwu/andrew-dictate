import AppKit

@MainActor
enum MenuBarBrandIcon {
    private static let iconSize = NSSize(width: 18, height: 18)

    static func image(
        for state: DictationCoordinator.State,
        needsAttention: Bool = false,
        isRecordingMeeting: Bool = false
    ) -> NSImage {
        // a permission gap outranks every other state: without it the other
        // states can never be reached anyway.
        if needsAttention {
            return attentionBadge()
        }
        // a meeting outranks dictation states because dictation is refused
        // while one runs (ADR 0023); the dot is the persistent indicator
        // the hud deliberately is not (ADR 0040). it is the same gold dot
        // dictation draws: gold means the mic is live, and which mic it is
        // belongs in the menu, not in a 6 pt disc.
        if isRecordingMeeting {
            let meeting = badge(recording: true)
            meeting.accessibilityDescription = "Andrew Dictate recording a meeting"
            return meeting
        }

        switch state {
        case .transcribing:
            if let hourglass = NSImage(
                systemSymbolName: "hourglass",
                accessibilityDescription: "Transcribing"
            ) {
                hourglass.isTemplate = true
                return hourglass
            }
            return badge(recording: false)
        case .recording:
            return badge(recording: true)
        case .idle,
             .prewarming:
            return badge(recording: false)
        }
    }

    /// the badge wearing a warning dot. red and top-right — gold means the
    /// mic is live (dictation or a meeting), so "needs you" differs from
    /// "listening" in both hue and corner.
    private static func attentionBadge() -> NSImage {
        guard let base = NSImage(named: "MenuBarBadge") else {
            let fallback = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription:
                    "Andrew Dictate needs permission"
            ) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }

        let composed = NSImage(size: iconSize, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(
                x: rect.maxX - 6.5,
                y: rect.maxY - 6,
                width: 6,
                height: 6
            )
            BrandUI.nsColor(BrandUI.attentionRGB).setFill()
            NSBezierPath(ovalIn: dot).fill()
            BrandUI.nsColor(BrandUI.blackRGB).setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        composed.isTemplate = false
        composed.accessibilityDescription =
            "Andrew Dictate needs permission"
        return composed
    }

    /// the actual brand badge, full color. non-template by design: the logo
    /// is the logo, everywhere (user directive).
    private static func badge(recording: Bool) -> NSImage {
        guard let base = NSImage(named: "MenuBarBadge") else {
            let fallback = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Andrew Dictate"
            ) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }

        guard recording else {
            base.size = iconSize
            base.isTemplate = false
            return base
        }

        let composed = NSImage(size: iconSize, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 6.5, y: rect.minY, width: 6, height: 6)
            BrandUI.nsColor(BrandUI.goldRGB).setFill()
            NSBezierPath(ovalIn: dot).fill()
            BrandUI.nsColor(BrandUI.blackRGB).setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 1
            ring.stroke()
            return true
        }
        composed.isTemplate = false
        composed.accessibilityDescription = "Andrew Dictate recording"
        return composed
    }
}
