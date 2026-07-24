import AppKit

@MainActor
enum MenuBarBrandIcon {
    private static let iconSize = NSSize(width: 30, height: 18)

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
            return brandImage(isRecording: false)
        case .recording:
            return brandImage(isRecording: true)
        case .idle, .prewarming, .gatePending:
            return brandImage(isRecording: false)
        }
    }

    private static func brandImage(isRecording: Bool) -> NSImage {
        let image = NSImage(
            size: iconSize,
            flipped: false
        ) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let horizontalInset: CGFloat = 2
            let scale = (
                iconSize.width - horizontalInset * 2
            ) / BrandMarkGeometry.centerlineSize.width
            let renderedHeight =
                BrandMarkGeometry.centerlineSize.height * scale
            let origin = CGPoint(
                x: horizontalInset,
                y: (iconSize.height - renderedHeight) / 2
            )
            func rendered(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: origin.x + point.x * scale,
                    y: origin.y
                        + (
                            BrandMarkGeometry.centerlineSize.height
                                - point.y
                        ) * scale
                )
            }

            let lineWidth: CGFloat = isRecording ? 1.7 : 1.2

            for points in [
                BrandMarkGeometry.firstDash,
                BrandMarkGeometry.secondDash,
                BrandMarkGeometry.rise,
            ] {
                let path = NSBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round

                guard let first = points.first else {
                    continue
                }
                path.move(to: rendered(first))
                for point in points.dropFirst() {
                    path.line(to: rendered(point))
                }
                path.stroke()
            }

            let dotCenter = rendered(BrandMarkGeometry.dotCenter)
            let dotRadius = BrandMarkGeometry.dotRadius * scale
            let dotRect = NSRect(
                x: dotCenter.x - dotRadius,
                y: dotCenter.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            let dot = NSBezierPath(ovalIn: dotRect)
            if isRecording {
                dot.fill()
            } else {
                dot.lineWidth = 0.9
                dot.stroke()
            }

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isRecording
            ? "Andrew Dictate recording"
            : "Andrew Dictate"
        return image
    }
}
