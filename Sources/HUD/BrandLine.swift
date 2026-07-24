import SwiftUI

enum BrandPalette {
    static let background = Color(
        red: 27.0 / 255.0,
        green: 27.0 / 255.0,
        blue: 31.0 / 255.0
    )
    static let cream = Color(
        red: 239.0 / 255.0,
        green: 234.0 / 255.0,
        blue: 224.0 / 255.0
    )
    static let persimmon = Color(
        red: 228.0 / 255.0,
        green: 89.0 / 255.0,
        blue: 59.0 / 255.0
    )
}

enum BrandMarkGeometry {
    static let centerlineSize = CGSize(width: 332, height: 118)
    static let drawingBounds = CGRect(
        x: -12,
        y: -12,
        width: 356,
        height: 154
    )
    static let firstDash = [
        CGPoint(x: 0, y: 118),
        CGPoint(x: 52, y: 118),
    ]
    static let secondDash = [
        CGPoint(x: 76, y: 118),
        CGPoint(x: 138, y: 118),
    ]
    static let rise = [
        CGPoint(x: 204, y: 118),
        CGPoint(x: 250, y: 72),
        CGPoint(x: 274, y: 94),
        CGPoint(x: 332, y: 0),
    ]
    static let dotCenter = CGPoint(x: 172, y: 118)
    static let dotRadius: CGFloat = 21
}

struct StaticBrandMark: View {
    var lineColor: Color = .primary
    var dotColor: Color = BrandPalette.persimmon

    var body: some View {
        Canvas { context, size in
            let bounds = BrandMarkGeometry.drawingBounds
            let scaleX = size.width / bounds.width
            let scaleY = size.height / bounds.height
            let strokeScale = min(scaleX, scaleY)
            let strokeStyle = StrokeStyle(
                lineWidth: 18 * strokeScale,
                lineCap: .round,
                lineJoin: .round
            )

            for points in [
                BrandMarkGeometry.firstDash,
                BrandMarkGeometry.secondDash,
                BrandMarkGeometry.rise,
            ] {
                let path = Path { path in
                    guard let first = points.first else {
                        return
                    }
                    path.move(to: scaled(first))
                    for point in points.dropFirst() {
                        path.addLine(to: scaled(point))
                    }
                }
                context.stroke(
                    path,
                    with: .color(lineColor),
                    style: strokeStyle
                )
            }

            let center = scaled(BrandMarkGeometry.dotCenter)
            let radius = BrandMarkGeometry.dotRadius * strokeScale
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                ),
                with: .color(dotColor)
            )

            func scaled(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: (point.x - bounds.minX) * scaleX,
                    y: (point.y - bounds.minY) * scaleY
                )
            }
        }
        .accessibilityHidden(true)
    }
}

enum BrandLinePhase: Equatable {
    case recording
    case transcribing
}

struct BrandLine: View {
    private enum Metrics {
        static let size = CGSize(width: 192, height: 38)
        static let baselineY: CGFloat = 29
        static let strokeWidth: CGFloat = 5
        static let dotCenter = CGPoint(x: 57, y: baselineY)
        static let dotRadius: CGFloat = 3.2
        static let suffixX: [CGFloat] = [
            68,
            90,
            109.69,
            131.45,
            156,
            184,
        ]
        static let staticRise = [
            CGPoint(x: 68, y: baselineY),
            CGPoint(x: 109.69, y: 17.72),
            CGPoint(x: 131.45, y: 23.14),
            CGPoint(x: 184, y: 6),
        ]
    }

    let phase: BrandLinePhase
    let mode: DictationMode?
    let levels: BrandLineLevelRing
    let transitionStartedAt: Date

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || phase != .transcribing
            )
        ) { timeline in
            Canvas { context, size in
                draw(
                    in: &context,
                    size: size,
                    date: timeline.date
                )
            }
        }
        .frame(width: Metrics.size.width, height: Metrics.size.height)
        .accessibilityHidden(true)
    }

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let scaleX = size.width / Metrics.size.width
        let scaleY = size.height / Metrics.size.height
        let strokeScale = min(scaleX, scaleY)
        let strokeStyle = StrokeStyle(
            lineWidth: Metrics.strokeWidth * strokeScale,
            lineCap: .round,
            lineJoin: .round
        )
        let isCommandRecording =
            phase == .recording && mode == .command
        let lineColor = isCommandRecording
            ? BrandPalette.persimmon
            : BrandPalette.cream

        let prefix = scaledPath(
            points: [
                CGPoint(x: 3, y: Metrics.baselineY),
                CGPoint(x: 19, y: Metrics.baselineY),
            ],
            scaleX: scaleX,
            scaleY: scaleY
        )
        let secondDash = scaledPath(
            points: [
                CGPoint(x: 26, y: Metrics.baselineY),
                CGPoint(x: 45, y: Metrics.baselineY),
            ],
            scaleX: scaleX,
            scaleY: scaleY
        )

        context.stroke(
            prefix,
            with: .color(lineColor),
            style: strokeStyle
        )
        context.stroke(
            secondDash,
            with: .color(lineColor),
            style: strokeStyle
        )

        let suffixPoints = renderedSuffixPoints(at: date)
        let suffix = scaledPath(
            points: suffixPoints,
            scaleX: scaleX,
            scaleY: scaleY
        )
        let suffixOpacity = breathingOpacity(at: date)
        context.stroke(
            suffix,
            with: .color(lineColor.opacity(suffixOpacity)),
            style: strokeStyle
        )

        if phase == .transcribing, !reduceMotion {
            let shimmerCenter = shimmerX(at: date, width: size.width)
            let shimmer = Gradient(colors: [
                .clear,
                BrandPalette.cream.opacity(0.22),
                .clear,
            ])
            context.stroke(
                suffix,
                with: .linearGradient(
                    shimmer,
                    startPoint: CGPoint(
                        x: shimmerCenter - 24,
                        y: size.height / 2
                    ),
                    endPoint: CGPoint(
                        x: shimmerCenter + 24,
                        y: size.height / 2
                    )
                ),
                style: strokeStyle
            )
        }

        let dotCenter = CGPoint(
            x: Metrics.dotCenter.x * scaleX,
            y: Metrics.dotCenter.y * scaleY
        )
        let dotRadius = Metrics.dotRadius * strokeScale
        let dotPath = Path(
            ellipseIn: CGRect(
                x: dotCenter.x - dotRadius,
                y: dotCenter.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
        )
        context.fill(
            dotPath,
            with: .color(BrandPalette.persimmon)
        )
    }

    private func renderedSuffixPoints(at date: Date) -> [CGPoint] {
        if reduceMotion {
            let heightScale = 0.92
                + CGFloat(levels.latestLevel) * 0.14
            return Metrics.staticRise.map { point in
                CGPoint(
                    x: point.x,
                    y: Metrics.baselineY
                        - (Metrics.baselineY - point.y) * heightScale
                )
            }
        }

        let livePoints = liveSuffixPoints()
        guard phase == .transcribing else {
            return livePoints
        }

        let targetPoints = Metrics.suffixX.map {
            CGPoint(x: $0, y: staticRiseY(at: $0))
        }
        let elapsed = max(
            0,
            date.timeIntervalSince(transitionStartedAt)
        )
        let linearProgress = min(CGFloat(elapsed / 0.42), 1)
        let easedProgress = linearProgress * linearProgress
            * (3 - 2 * linearProgress)

        return zip(livePoints, targetPoints).map { live, target in
            CGPoint(
                x: live.x,
                y: live.y + (target.y - live.y) * easedProgress
            )
        }
    }

    private func liveSuffixPoints() -> [CGPoint] {
        let offsets = BrandLineJointMapper.verticalOffsets(
            in: levels,
            jointCount: Metrics.suffixX.count - 1,
            maximumAmplitude: 6.5
        )

        return Metrics.suffixX.enumerated().map { index, x in
            guard index > 0 else {
                return CGPoint(x: x, y: Metrics.baselineY)
            }

            let progress = CGFloat(index)
                / CGFloat(Metrics.suffixX.count - 1)
            let baseline = Metrics.baselineY - progress * 18
            return CGPoint(
                x: x,
                y: baseline + CGFloat(offsets[index - 1])
            )
        }
    }

    private func staticRiseY(at x: CGFloat) -> CGFloat {
        for index in 0..<(Metrics.staticRise.count - 1) {
            let start = Metrics.staticRise[index]
            let end = Metrics.staticRise[index + 1]

            if x <= end.x {
                let progress = (x - start.x) / (end.x - start.x)
                return start.y + (end.y - start.y) * progress
            }
        }

        return Metrics.staticRise.last?.y ?? Metrics.baselineY
    }

    private func breathingOpacity(at date: Date) -> Double {
        guard phase == .transcribing, !reduceMotion else {
            return 1
        }

        let elapsed = date.timeIntervalSince(transitionStartedAt)
        return 0.92 + 0.08 * (
            0.5 + 0.5 * sin(elapsed * .pi * 2 / 1.8)
        )
    }

    private func shimmerX(at date: Date, width: CGFloat) -> CGFloat {
        let elapsed = max(
            0,
            date.timeIntervalSince(transitionStartedAt)
        )
        let progress = elapsed.truncatingRemainder(
            dividingBy: 1.6
        ) / 1.6
        return -24 + (width + 48) * CGFloat(progress)
    }

    private func scaledPath(
        points: [CGPoint],
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> Path {
        Path { path in
            guard let firstPoint = points.first else {
                return
            }

            path.move(
                to: CGPoint(
                    x: firstPoint.x * scaleX,
                    y: firstPoint.y * scaleY
                )
            )
            for point in points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: point.x * scaleX,
                        y: point.y * scaleY
                    )
                )
            }
        }
    }
}

struct BrandLinePrefix: View {
    private static let referenceSize = CGSize(width: 64, height: 14)

    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / Self.referenceSize.width
            let scaleY = size.height / Self.referenceSize.height
            let strokeScale = min(scaleX, scaleY)
            let strokeStyle = StrokeStyle(
                lineWidth: 5 * strokeScale,
                lineCap: .round,
                lineJoin: .round
            )

            for segment in [
                (CGPoint(x: 3, y: 7), CGPoint(x: 19, y: 7)),
                (CGPoint(x: 26, y: 7), CGPoint(x: 45, y: 7)),
            ] {
                var path = Path()
                path.move(
                    to: CGPoint(
                        x: segment.0.x * scaleX,
                        y: segment.0.y * scaleY
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: segment.1.x * scaleX,
                        y: segment.1.y * scaleY
                    )
                )
                context.stroke(
                    path,
                    with: .color(BrandPalette.cream),
                    style: strokeStyle
                )
            }

            let dotRadius = 3.2 * strokeScale
            let dotCenter = CGPoint(
                x: 57 * scaleX,
                y: 7 * scaleY
            )
            let dotPath = Path(
                ellipseIn: CGRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
            )
            context.fill(
                dotPath,
                with: .color(BrandPalette.persimmon)
            )
        }
        .frame(
            width: Self.referenceSize.width,
            height: Self.referenceSize.height
        )
        .accessibilityHidden(true)
    }
}
