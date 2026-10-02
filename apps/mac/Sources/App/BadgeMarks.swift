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
        /// a call nobody records: a viewfinder, you could catch this.
        case brackets
        /// getting ready, or writing it out: the rim part of the way round.
        case partRim
        /// recording a meeting: the whole rim.
        case rim
        /// a meeting's problem: a red triangle with a black "!".
        case warning
    }

    /// which mark each look wears.
    static func mark(for look: BadgeLook) -> Mark? {
        switch look {
        case .idle: nil
        case .dictating: .liveDot
        case .callNotRecorded: .brackets
        case .gettingReady: .partRim
        case .recordingMeeting: .rim
        case .meetingProblem: .warning
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
    /// the brand black, half a point in from the right edge. gold and
    /// bottom right for a take, red and top right for setup: gold means
    /// the mic is live, so "needs you" differs from "listening" in both
    /// hue and corner. the ring is stroked on the dot's edge, so the canvas
    /// clips its outer half where the dot touches the top or bottom; that
    /// is how it has always shipped.
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
        /// how far round getting ready goes, clockwise from the top middle.
        static let readyShare: CGFloat = 0.36
        /// the rest of the way round, so the part reads as a part.
        static let trackOpacity: CGFloat = 0.2
    }

    /// the rim at the four corners only.
    enum Brackets {
        /// from the badge's edge to the end of each arm.
        static let reach: CGFloat = 5.5
    }

    /// a red triangle in the bottom-right corner, its red inside that
    /// quarter of the badge, with a black outline to part it from the gold
    /// mic underneath.
    enum Warning {
        static let apex = NSPoint(x: 13, y: 9)
        static let baseLeft = NSPoint(x: 9, y: 1)
        static let baseRight = NSPoint(x: 17, y: 1)
        static let outline: CGFloat = 1
        static let stem = NSRect(x: 12.5, y: 4, width: 1, height: 2.5)
        static let point = NSRect(x: 12.5, y: 2, width: 1, height: 1)
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
        case .brackets:
            drawBrackets(in: rect)
        case .partRim:
            drawPartRim(in: rect)
        case .rim:
            gold.setStroke()
            rimPath(in: rect).stroke()
        case .warning:
            drawWarning(in: rect)
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

    private static func drawPartRim(in rect: NSRect) {
        gold.withAlphaComponent(Rim.trackOpacity).setStroke()
        rimPath(in: rect).stroke()

        let (part, length) = rimPathAndLength(in: rect)
        part.setLineDash(
            [length * Rim.readyShare, length],
            count: 2,
            phase: 0
        )
        gold.setStroke()
        part.stroke()
    }

    /// the whole rim seen through four square windows, one per corner, so
    /// the brackets are the rim exactly and each arm ends square on the
    /// pixel grid.
    private static func drawBrackets(in rect: NSRect) {
        let scale = deviceScale()
        let reach = snapped(Brackets.reach, scale: scale)
        let corners = NSBezierPath()
        for (x, y) in [
            (rect.minX, rect.minY),
            (rect.maxX - reach, rect.minY),
            (rect.minX, rect.maxY - reach),
            (rect.maxX - reach, rect.maxY - reach)
        ] {
            corners.appendRect(NSRect(x: x, y: y, width: reach, height: reach))
        }

        NSGraphicsContext.saveGraphicsState()
        corners.addClip()
        gold.setStroke()
        rimPath(in: rect).stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawWarning(in rect: NSRect) {
        let origin = NSPoint(x: rect.minX, y: rect.minY)
        let triangle = NSBezierPath()
        triangle.move(to: Warning.apex.offset(by: origin))
        triangle.line(to: Warning.baseRight.offset(by: origin))
        triangle.line(to: Warning.baseLeft.offset(by: origin))
        triangle.close()

        // the outline is the stroke's outer half; the red fill covers the
        // inner half, so the red keeps the exact corners above.
        triangle.lineWidth = Warning.outline * 2
        triangle.lineJoinStyle = .round
        black.setStroke()
        triangle.stroke()
        red.setFill()
        triangle.fill()

        // the "!" sits on the triangle's centre line, which is half a
        // pixel off the grid on a 1x screen: there it moves the half pixel
        // rather than smear over two.
        let scale = deviceScale()
        black.setFill()
        for part in [Warning.stem, Warning.point] {
            NSBezierPath(
                rect: snapped(
                    part.offsetBy(dx: origin.x, dy: origin.y),
                    scale: scale
                )
            ).fill()
        }
    }

    private static func rimPath(in rect: NSRect) -> NSBezierPath {
        rimPathAndLength(in: rect).path
    }

    /// the rim's centre line, starting at the top middle and running
    /// clockwise, so a dash from phase 0 fills it the way a clock does,
    /// and how long it is. both of its edges land on whole device pixels,
    /// and its corners curve round the same points the tile's do.
    private static func rimPathAndLength(
        in rect: NSRect
    ) -> (path: NSBezierPath, length: CGFloat) {
        let scale = deviceScale()
        let outer = snapped(Tile.inset, scale: scale)
        let width = max(1 / scale, snapped(Rim.width, scale: scale))
        let band = rect.insetBy(dx: outer + width / 2, dy: outer + width / 2)
        let radius = Tile.cornerCentre - (outer + width / 2)
        let length = 4 * (band.width - 2 * radius) + 2 * .pi * radius

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
        return (path, length)
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

    private static func snapped(_ rect: NSRect, scale: CGFloat) -> NSRect {
        let minX = snapped(rect.minX, scale: scale)
        let minY = snapped(rect.minY, scale: scale)
        return NSRect(
            x: minX,
            y: minY,
            width: snapped(rect.maxX, scale: scale) - minX,
            height: snapped(rect.maxY, scale: scale) - minY
        )
    }
}

private extension NSPoint {
    func offset(by origin: NSPoint) -> NSPoint {
        NSPoint(x: x + origin.x, y: y + origin.y)
    }
}
