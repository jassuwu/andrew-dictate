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
        /// recording a meeting: the whole rim.
        case rim
    }

    /// which mark each look wears.
    static func mark(for look: BadgeLook) -> Mark? {
        switch look {
        case .idle: nil
        case .dictating: .liveDot
        case .callNotRecorded: nil
        case .gettingReady: nil
        case .recordingMeeting: .rim
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

    /// the tile inside the asset, which the rim and the brackets are drawn
    /// over: inset 0.36 pt, its corners curving round a point 4.25 pt in
    /// from both edges. measured off menubar_36.png, not chosen.
    enum Tile {
        static let inset: CGFloat = 0.36
        static let cornerCentre: CGFloat = 4.25
    }

    /// the gold edge. it lies over the tile's own outer edge, not outside
    /// it, so the badge keeps its size and the face keeps its room. where
    /// it starts and how wide it is are rounded to whole device pixels:
    /// 1 pt wide on a 1x screen, 1.5 pt on a 2x one, never a smeared 1.3.
    enum Rim {
        static let width: CGFloat = 1.3
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
        case .rim:
            gold.setStroke()
            rimPath(in: rect).stroke()
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

    /// the rim's centre line, starting at the top middle and running
    /// clockwise. both of its edges land on whole device pixels, and its
    /// corners curve round the same points the tile's do.
    private static func rimPath(in rect: NSRect) -> NSBezierPath {
        let scale = deviceScale()
        let outer = snapped(Tile.inset, scale: scale)
        let width = max(1 / scale, snapped(Rim.width, scale: scale))
        let band = rect.insetBy(dx: outer + width / 2, dy: outer + width / 2)
        let radius = Tile.cornerCentre - (outer + width / 2)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: band.midX, y: band.maxY))
        path.line(to: NSPoint(x: band.maxX - radius, y: band.maxY))
        path.appendArc(
            withCenter: NSPoint(x: band.maxX - radius, y: band.maxY - radius),
            radius: radius,
            startAngle: 90,
            endAngle: 0,
            clockwise: true
        )
        path.line(to: NSPoint(x: band.maxX, y: band.minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: band.maxX - radius, y: band.minY + radius),
            radius: radius,
            startAngle: 0,
            endAngle: -90,
            clockwise: true
        )
        path.line(to: NSPoint(x: band.minX + radius, y: band.minY))
        path.appendArc(
            withCenter: NSPoint(x: band.minX + radius, y: band.minY + radius),
            radius: radius,
            startAngle: -90,
            endAngle: -180,
            clockwise: true
        )
        path.line(to: NSPoint(x: band.minX, y: band.maxY - radius))
        path.appendArc(
            withCenter: NSPoint(x: band.minX + radius, y: band.maxY - radius),
            radius: radius,
            startAngle: 180,
            endAngle: 90,
            clockwise: true
        )
        path.close()
        path.lineWidth = width
        return path
    }

    /// pixels per point where this is being drawn: 1 on an external
    /// non-retina screen, 2 on the built-in one.
    private static func deviceScale() -> CGFloat {
        guard let context = NSGraphicsContext.current else {
            return 1
        }
        let transform = context.cgContext.userSpaceToDeviceSpaceTransform
        let scale = hypot(transform.a, transform.b)
        return scale > 0 ? scale : 1
    }

    /// to the nearest whole device pixel, so a straight edge lands on the
    /// pixel grid instead of smearing across two.
    private static func snapped(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
