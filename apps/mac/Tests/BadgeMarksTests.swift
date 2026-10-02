import AppKit
import XCTest

/// what a person checks by eye, asked of the rendered pixels at 1x and 2x:
/// where the gold and the red land, and where they don't. no whole-image
/// snapshots, so a nudge to a mark's geometry fails only if it moves a
/// mark somewhere it should not be.
final class BadgeMarksTests: XCTestCase {
    private let scales = [1, 2]

    /// the item never changes width: a wider image shoves every icon to
    /// its left sideways and back.
    func testEveryLookKeepsTheItemEighteenPointsSquare() {
        for look in BadgeLook.allCases {
            let image = BadgeMarks.image(for: look, on: badge())

            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(look)")
            XCTAssertFalse(image.isTemplate, "\(look)")
        }
    }

    func testTheBareBadgeIsTheShippedAsset() {
        for scale in scales {
            let idle = render(
                BadgeMarks.image(for: .idle, on: badge()),
                scale: scale
            )

            XCTAssertEqual(idle, render(badge(), scale: scale), "\(scale)x")
        }
    }

    func testRecordingIsGoldAllTheWayRound() {
        for scale in scales {
            let rendered = render(.recordingMeeting, scale: scale)

            for edge in Edge.allCases {
                XCTAssertTrue(
                    rendered.has(gold, in: edge.middle),
                    "\(edge) at \(scale)x"
                )
            }
        }
    }

    // MARK: - what is looked for, and where

    private let gold = BrandUI.goldRGB

    /// two points deep along each edge, four long round its middle: where
    /// a rim lies and a corner bracket does not reach.
    private enum Edge: CaseIterable {
        case top, right, bottom, left

        var middle: NSRect {
            switch self {
            case .top: NSRect(x: 7, y: 16, width: 4, height: 2)
            case .right: NSRect(x: 16, y: 7, width: 2, height: 4)
            case .bottom: NSRect(x: 7, y: 0, width: 4, height: 2)
            case .left: NSRect(x: 0, y: 7, width: 2, height: 4)
            }
        }
    }

    // MARK: - rendering

    private func render(_ look: BadgeLook, scale: Int) -> Rendered {
        render(BadgeMarks.image(for: look, on: badge()), scale: scale)
    }

    /// drawn the way the menu bar draws it: into a context with `scale`
    /// pixels per point, transparent behind.
    private func render(_ image: NSImage, scale: Int) -> Rendered {
        let side = 18 * scale
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context,
            flipped: false
        )
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()

        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return Rendered(
            scale: scale,
            bytes: Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
        )
    }

    /// the asset's two pngs, read from the source tree: the test bundle
    /// has no asset catalog to ask.
    private func badge() -> NSImage {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/Assets.xcassets/MenuBarBadge.imageset"
            )
        let image = NSImage(size: BadgeMarks.size)
        for file in ["menubar_18.png", "menubar_36.png"] {
            let data = try! Data(contentsOf: folder.appendingPathComponent(file))
            let rep = NSBitmapImageRep(data: data)!
            rep.size = BadgeMarks.size
            image.addRepresentation(rep)
        }
        return image
    }
}

/// a rendered badge, RGBA, top row first.
private struct Rendered: Equatable {
    let scale: Int
    let bytes: [UInt8]

    /// an opaque pixel within a few values of `rgb` in every channel: the
    /// mark itself, not an edge blended into the badge behind it.
    func has(_ rgb: [Double], in region: NSRect) -> Bool {
        pixels(in: region).contains { Self.matches($0, rgb) }
    }

    /// every pixel whose centre lies in `region`, given in points, y up
    /// like the drawing.
    private func pixels(in region: NSRect) -> [[UInt8]] {
        let side = 18 * scale
        var found: [[UInt8]] = []
        for row in 0..<side {
            for column in 0..<side {
                let centre = NSPoint(
                    x: (Double(column) + 0.5) / Double(scale),
                    y: 18 - (Double(row) + 0.5) / Double(scale)
                )
                guard region.contains(centre) else {
                    continue
                }
                let start = (row * side + column) * 4
                found.append(Array(bytes[start..<start + 4]))
            }
        }
        return found
    }

    private static func matches(_ pixel: [UInt8], _ rgb: [Double]) -> Bool {
        pixel[3] == 255
            && (0..<3).allSatisfy { abs(Double(pixel[$0]) - rgb[$0]) <= 16 }
    }
}
