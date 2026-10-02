import AppKit

/// every mark the menu bar badge can wear, each one's geometry in one enum
/// below. the meeting marks were picked from mockups: the tile's own edge
/// in gold for a meeting, a red triangle for a problem. a different pick is
/// a different line in `mark(for:)`, or different numbers in one enum.
///
/// all of it is drawn over the badge, in the badge's 18 pt square, y up.
enum BadgeMarks {
    /// the item never changes width, whatever the badge wears: a wider
    /// image shoves every icon to its left sideways and back.
    static let size = NSSize(width: 18, height: 18)

    enum Mark: Equatable, Sendable {
        /// a take: the gold dot, bottom right.
        case liveDot
        /// a setup gap: the red dot, top right.
        case setupDot
    }

    /// which mark each look wears.
    static func mark(for look: BadgeLook) -> Mark? {
        switch look {
        case .idle: nil
        case .dictating: .liveDot
        case .callNotRecorded: nil
        case .gettingReady: nil
        case .recordingMeeting: nil
        case .meetingProblem: nil
        case .needsSetup: .setupDot
        }
    }

    /// the badge wearing `look`'s mark. the bare look hands the badge back
    /// untouched, so idle is the shipped asset and nothing drawn over it.
    static func image(for look: BadgeLook, on badge: NSImage) -> NSImage {
        guard let mark = mark(for: look) else {
            return badge
        }
        let composed = NSImage(size: size, flipped: false) { rect in
            badge.draw(in: rect)
            draw(mark, in: rect)
            return true
        }
        composed.isTemplate = false
        return composed
    }

    // MARK: - geometry, one enum per mark

    /// the dot a take and a setup gap have always worn: 6 pt, ringed in
    /// the brand black, half a point in from the right edge. the ring is
    /// stroked on the dot's edge, so the canvas clips its outer half where
    /// the dot touches the top or bottom; that is how it has always shipped.
    enum Dot {
        static let diameter: CGFloat = 6
        static let ring: CGFloat = 1
        static let fromRight: CGFloat = 0.5
    }

    // MARK: - drawing

    private static let gold = BrandUI.nsColor(BrandUI.goldRGB)
    private static let black = BrandUI.nsColor(BrandUI.blackRGB)
    private static let red = BrandUI.nsColor(BrandUI.attentionRGB)

    private static func draw(_ mark: Mark, in rect: NSRect) {
        switch mark {
        case .liveDot:
            drawDot(
                NSRect(
                    x: rect.maxX - Dot.diameter - Dot.fromRight,
                    y: rect.minY,
                    width: Dot.diameter,
                    height: Dot.diameter
                ),
                color: gold
            )
        case .setupDot:
            drawDot(
                NSRect(
                    x: rect.maxX - Dot.diameter - Dot.fromRight,
                    y: rect.maxY - Dot.diameter,
                    width: Dot.diameter,
                    height: Dot.diameter
                ),
                color: red
            )
        }
    }

    private static func drawDot(_ dot: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        black.setStroke()
        let ring = NSBezierPath(ovalIn: dot)
        ring.lineWidth = Dot.ring
        ring.stroke()
    }
}
