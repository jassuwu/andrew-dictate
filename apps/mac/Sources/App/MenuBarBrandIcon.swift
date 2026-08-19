import AppKit

@MainActor
enum MenuBarBrandIcon {
    private static let iconSize = NSSize(width: 18, height: 18)

    static func image(
        for state: DictationCoordinator.State,
        needsAttention: Bool = false
    ) -> NSImage {
        // a permission gap outranks every other state: without it the other
        // states can never be reached anyway.
        if needsAttention {
            return attentionBadge()
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

    /// the badge wearing a warning dot. deliberately not gold — gold means
    /// recording, and "we're listening" is the one thing this state isn't.
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
                y: rect.minY,
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
