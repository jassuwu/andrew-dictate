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

            let head = headPath()
            let leftLens = lensPath(isLeft: true)
            let rightLens = lensPath(isLeft: false)
            let microphone = microphonePath()

            if isRecording {
                head.fill()
                cutOut(leftLens)
                cutOut(rightLens)
                microphone.fill()
                cutOutGrilleSlats()
            } else {
                head.lineWidth = 1.15
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                head.stroke()

                microphone.lineWidth = 1.05
                microphone.lineCapStyle = .round
                microphone.lineJoinStyle = .round
                microphone.stroke()
            }

            let aviatorBand = NSBezierPath()
            aviatorBand.move(to: NSPoint(x: 3.6, y: 10.4))
            aviatorBand.line(to: NSPoint(x: 14.4, y: 10.4))
            aviatorBand.lineWidth = 0.85
            aviatorBand.lineCapStyle = .round
            aviatorBand.stroke()

            for lens in [leftLens, rightLens] {
                lens.lineWidth = 0.9
                lens.lineCapStyle = .round
                lens.lineJoinStyle = .round
                lens.stroke()
            }

            if !isRecording {
                drawGrilleSlats()
            }

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isRecording
            ? "Andrew Dictate recording"
            : "Andrew Dictate"
        return image
    }

    private static func headPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3.7, y: 7.1))
        path.curve(
            to: NSPoint(x: 4.7, y: 14.0),
            controlPoint1: NSPoint(x: 3.5, y: 10.8),
            controlPoint2: NSPoint(x: 3.8, y: 12.8)
        )
        path.curve(
            to: NSPoint(x: 9.0, y: 16.8),
            controlPoint1: NSPoint(x: 5.8, y: 15.8),
            controlPoint2: NSPoint(x: 7.3, y: 16.8)
        )
        path.curve(
            to: NSPoint(x: 13.3, y: 14.0),
            controlPoint1: NSPoint(x: 10.7, y: 16.8),
            controlPoint2: NSPoint(x: 12.2, y: 15.8)
        )
        path.curve(
            to: NSPoint(x: 14.3, y: 7.1),
            controlPoint1: NSPoint(x: 14.2, y: 12.8),
            controlPoint2: NSPoint(x: 14.5, y: 10.8)
        )
        path.curve(
            to: NSPoint(x: 11.7, y: 5.4),
            controlPoint1: NSPoint(x: 13.8, y: 6.2),
            controlPoint2: NSPoint(x: 12.9, y: 5.6)
        )
        path.line(to: NSPoint(x: 6.3, y: 5.4))
        path.curve(
            to: NSPoint(x: 3.7, y: 7.1),
            controlPoint1: NSPoint(x: 5.1, y: 5.6),
            controlPoint2: NSPoint(x: 4.2, y: 6.2)
        )
        path.close()
        return path
    }

    private static func lensPath(isLeft: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        if isLeft {
            path.move(to: NSPoint(x: 4.1, y: 10.3))
            path.curve(
                to: NSPoint(x: 8.6, y: 10.2),
                controlPoint1: NSPoint(x: 5.5, y: 10.8),
                controlPoint2: NSPoint(x: 7.4, y: 10.7)
            )
            path.curve(
                to: NSPoint(x: 6.4, y: 7.4),
                controlPoint1: NSPoint(x: 8.2, y: 8.4),
                controlPoint2: NSPoint(x: 7.3, y: 7.4)
            )
            path.curve(
                to: NSPoint(x: 4.1, y: 10.3),
                controlPoint1: NSPoint(x: 5.1, y: 7.4),
                controlPoint2: NSPoint(x: 4.2, y: 8.5)
            )
        } else {
            path.move(to: NSPoint(x: 13.9, y: 10.3))
            path.curve(
                to: NSPoint(x: 9.4, y: 10.2),
                controlPoint1: NSPoint(x: 12.5, y: 10.8),
                controlPoint2: NSPoint(x: 10.6, y: 10.7)
            )
            path.curve(
                to: NSPoint(x: 11.6, y: 7.4),
                controlPoint1: NSPoint(x: 9.8, y: 8.4),
                controlPoint2: NSPoint(x: 10.7, y: 7.4)
            )
            path.curve(
                to: NSPoint(x: 13.9, y: 10.3),
                controlPoint1: NSPoint(x: 12.9, y: 7.4),
                controlPoint2: NSPoint(x: 13.8, y: 8.5)
            )
        }
        path.close()
        return path
    }

    private static func microphonePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 6.3, y: 6.7))
        path.line(to: NSPoint(x: 6.3, y: 3.7))
        path.curve(
            to: NSPoint(x: 9.0, y: 1.2),
            controlPoint1: NSPoint(x: 6.3, y: 2.1),
            controlPoint2: NSPoint(x: 7.4, y: 1.2)
        )
        path.curve(
            to: NSPoint(x: 11.7, y: 3.7),
            controlPoint1: NSPoint(x: 10.6, y: 1.2),
            controlPoint2: NSPoint(x: 11.7, y: 2.1)
        )
        path.line(to: NSPoint(x: 11.7, y: 6.7))
        path.close()
        return path
    }

    private static func drawGrilleSlats() {
        for (x, top) in [
            (7.6, 5.6),
            (9.0, 6.2),
            (10.4, 5.6),
        ] {
            let slat = NSBezierPath()
            slat.move(to: NSPoint(x: x, y: 3.2))
            slat.line(to: NSPoint(x: x, y: top))
            slat.lineWidth = 0.7
            slat.lineCapStyle = .round
            slat.stroke()
        }
    }

    private static func cutOut(_ path: NSBezierPath) {
        guard let context = NSGraphicsContext.current else {
            return
        }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        path.fill()
        context.restoreGraphicsState()
        NSColor.black.setStroke()
        NSColor.black.setFill()
    }

    private static func cutOutGrilleSlats() {
        guard let context = NSGraphicsContext.current else {
            return
        }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        NSColor.black.setStroke()
        drawGrilleSlats()
        context.restoreGraphicsState()
        NSColor.black.setStroke()
        NSColor.black.setFill()
    }
}
