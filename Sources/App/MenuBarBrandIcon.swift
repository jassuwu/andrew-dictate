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

            let lineWidth: CGFloat = isRecording ? 1.9 : 1.15
            let line = NSBezierPath()
            line.lineWidth = lineWidth
            line.lineCapStyle = .round
            line.lineJoinStyle = .round

            line.move(to: NSPoint(x: 1.5, y: 5.5))
            line.line(to: NSPoint(x: 5, y: 5.5))
            line.stroke()

            let rise = NSBezierPath()
            rise.lineWidth = lineWidth
            rise.lineCapStyle = .round
            rise.lineJoinStyle = .round
            rise.move(to: NSPoint(x: 10.5, y: 5.5))
            rise.line(to: NSPoint(x: 12.6, y: 9.2))
            rise.line(to: NSPoint(x: 14.1, y: 7.8))
            rise.line(to: NSPoint(x: 17, y: 13.7))
            rise.stroke()

            let dotRect = NSRect(
                x: 6.7,
                y: 4.7,
                width: 1.8,
                height: 1.8
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
