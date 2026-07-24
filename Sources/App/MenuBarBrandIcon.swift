import AppKit

@MainActor
enum MenuBarBrandIcon {
    private static let iconSize = NSSize(width: 18, height: 18)

    static func image(
        for state: DictationCoordinator.State
    ) -> NSImage {
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
             .prewarming,
             .asking,
             .askAnswer,
             .askThreadOpen,
             .gatePending,
             .transcriptFlash:
            return badge(recording: false)
        }
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
            NSColor(srgbRed: 0xE5 / 255, green: 0xBE / 255, blue: 0x62 / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255, alpha: 1).setStroke()
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
