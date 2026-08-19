import SwiftUI

/// motion constants for the lamp line. one source of truth — the coordinator
/// reads coolDuration so the panel outlives the afterglow by exactly enough.
enum HUDWaveMotion {
    static let igniteDuration: TimeInterval = 0.14
    static let coolDuration: TimeInterval = 0.30
    static let lineWidth: CGFloat = 86
    static let amplitude: CGFloat = 7.5
    static let strokeWidth: CGFloat = 2.6
    static let coreStrokeWidth: CGFloat = 1.1
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: DictationCoordinator.State
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var layout: HUDLayout
    @Published private(set) var presentationGeneration = 0
    /// shaped + thermally smoothed loudness: fast attack, slow release —
    /// a filament can't cool instantly.
    @Published private(set) var loudness: Float = 0
    @Published private(set) var waveTransitionStartedAt = Date()
    /// hands-free capture looks exactly like a held key unless the lamp
    /// says otherwise. the coordinator owns the fact; the line wears it.
    @Published private(set) var isRecordingLocked = false

    private var audioRecorder: AudioRecorder?
    private var levelSamplingTask: Task<Void, Never>?

    init(
        state: DictationCoordinator.State,
        audioRecorder: AudioRecorder?
    ) {
        self.state = state
        self.audioRecorder = audioRecorder
        layout = HUDLayoutEngine.layout(
            for: .prewarming,
            screenWidth: 1_440
        )
    }

    var content: HUDContent {
        if let feedbackMessage {
            return .text(feedbackMessage)
        }

        switch state {
        case .idle, .recording, .transcribing:
            return .wave
        case .prewarming:
            return .prewarming
        }
    }

    func update(state: DictationCoordinator.State) {
        let previousState = self.state

        if state != previousState {
            waveTransitionStartedAt = Date()
        }

        configureLevelSampling(
            for: state,
            previousState: previousState
        )
        self.state = state
        feedbackMessage = nil
        presentationGeneration += 1
    }

    /// not folded into `update(state:)`: the lock is set a beat after the
    /// recording starts, and must not restart the ignite animation.
    func setRecordingLocked(_ locked: Bool) {
        guard locked != isRecordingLocked else {
            return
        }
        isRecordingLocked = locked
    }

    /// the coordinator can rebuild the recorder mid-session, when an input
    /// device finally turns up — the wave has to follow the new one.
    func useRecorder(_ recorder: AudioRecorder?) {
        audioRecorder = recorder
    }

    func showFeedback(_ message: String) {
        feedbackMessage = message
        presentationGeneration += 1
    }

    func clearFeedback() {
        feedbackMessage = nil
        presentationGeneration += 1
    }

    func updateLayout(_ layout: HUDLayout) {
        guard layout != self.layout else {
            return
        }
        self.layout = layout
    }

    private func configureLevelSampling(
        for state: DictationCoordinator.State,
        previousState: DictationCoordinator.State
    ) {
        guard state == .recording else {
            levelSamplingTask?.cancel()
            levelSamplingTask = nil

            if state != .transcribing {
                loudness = 0
            }
            return
        }

        guard previousState != .recording else {
            return
        }

        loudness = 0
        sampleCurrentLevel(interval: 0.033)
        levelSamplingTask?.cancel()
        levelSamplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }

                self?.sampleCurrentLevel(interval: 0.033)
            }
        }
    }

    private func sampleCurrentLevel(interval: Double) {
        let shaped = WaveLevelShaper.shape(
            audioRecorder?.currentLevel ?? 0
        )
        let attack = 1 - exp(-interval / 0.040)
        let release = 1 - exp(-interval / 0.200)
        let gain = shaped > loudness ? attack : release
        loudness += (shaped - loudness) * Float(gain)
    }
}

struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        ZStack {
            if let feedbackMessage = viewModel.feedbackMessage {
                textPill(feedbackMessage)
                    .id(viewModel.presentationGeneration)
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.94))
                    )
            } else {
                switch viewModel.state {
                case .idle:
                    EmptyView()
                case .prewarming:
                    lampLine(phase: .ember)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Warming up")
                case .recording:
                    lampLine(phase: .burn)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            viewModel.isRecordingLocked
                                ? "Listening, locked"
                                : "Listening"
                        )
                case .transcribing:
                    lampLine(phase: .cool)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Transcribing")
                }
            }
        }
        .animation(
            reduceMotion || viewModel.feedbackMessage == nil
                ? nil
                : .snappy(duration: 0.32, extraBounce: 0.12),
            value: viewModel.presentationGeneration
        )
        .frame(
            width: viewModel.layout.size.width,
            height: viewModel.layout.size.height
        )
    }

    private func lampLine(phase: GoldRippleLine.Phase) -> some View {
        GoldRippleLine(
            phase: phase,
            loudness: viewModel.loudness,
            startedAt: viewModel.waveTransitionStartedAt,
            isLocked: viewModel.isRecordingLocked
        )
    }

    private func textPill(_ message: String) -> some View {
        Text(message)
            .font(Font(HUDLayoutEngine.primaryFont))
            .foregroundStyle(HUDGold.pale)
            .lineLimit(viewModel.layout.lineCount)
            .lineSpacing(HUDLayoutEngine.wrappedLineSpacing)
            .truncationMode(.tail)
            .padding(
                .horizontal,
                HUDLayoutEngine.horizontalPadding
            )
            .frame(
                width: viewModel.layout.size.width,
                height: viewModel.layout.size.height
            )
            .background {
                ZStack {
                    HUDGlassBackground()
                    HUDGold.black.opacity(0.22)
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 22,
                        style: .continuous
                    )
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: 22,
                    style: .continuous
                )
                .stroke(
                    HUDGold.mid.opacity(0.35),
                    lineWidth: 1
                )
            }
    }
}

enum HUDGold {
    static let pale = Color(
        red: 249.0 / 255.0,
        green: 233.0 / 255.0,
        blue: 168.0 / 255.0
    )
    static let mid = Color(
        red: 229.0 / 255.0,
        green: 190.0 / 255.0,
        blue: 98.0 / 255.0
    )
    static let deep = Color(
        red: 158.0 / 255.0,
        green: 117.0 / 255.0,
        blue: 39.0 / 255.0
    )
    static let black = Color(
        red: 11.0 / 255.0,
        green: 11.0 / 255.0,
        blue: 13.0 / 255.0
    )
}

/// the lamp: a bare gold line, bolted in place. flat ember when silent,
/// waving when voice hits it, tungsten color shift riding the loudness.
/// entrance and exit are CRT gestures — expands from a point on ignite,
/// collapses back into a hot dot on release. it never translates.
struct GoldRippleLine: View {
    enum Phase: Equatable {
        /// prewarming: dim line breathing slowly, no wave
        case ember
        /// recording: live wave, amplitude and heat ride the voice
        case burn
        /// transcribing: collapse to a dot, flash, afterglow — the goodbye
        case cool
    }

    let phase: Phase
    let loudness: Float
    let startedAt: Date
    /// double-tap lock: the key is no longer held, so the ends get pinned.
    var isLocked = false

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// derived from the line's own metrics so the pins scale with it —
    /// a hair thicker than the hot core, set just off each end.
    private static let lockDotRadius =
        HUDWaveMotion.coreStrokeWidth * 1.35
    private static let lockDotGap =
        HUDWaveMotion.strokeWidth * 2.2

    private static let paleRGB: [Double] = [249, 233, 168]
    private static let midRGB: [Double] = [229, 190, 98]
    private static let deepRGB: [Double] = [158, 117, 39]

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: reduceMotion
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
        .accessibilityHidden(true)
    }

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        date: Date
    ) {
        let cx = size.width / 2
        let cy = size.height / 2
        let elapsed = max(0, date.timeIntervalSince(startedAt))

        if reduceMotion {
            drawStatic(in: &context, cx: cx, cy: cy)
            return
        }

        var heat = 0.0
        var presence = 0.0
        var extent = 1.0
        var dotFlash = 0.0
        var damp = 1.0

        switch phase {
        case .ember:
            let breathe = sin(
                date.timeIntervalSinceReferenceDate
                    * .pi * 2 / 2.8
            )
            heat = 0.20 + 0.08 * breathe
            presence = 1
            damp = 0
        case .burn:
            let t = min(
                elapsed / HUDWaveMotion.igniteDuration,
                1
            )
            presence = min(t / 0.6, 1)
            extent = 1 - pow(1 - t, 3)
            heat = t < 0.75
                ? smoothstep(t / 0.75) * 1.12
                : lerp(1.12, 1, (t - 0.75) / 0.25)
        case .cool:
            let t = min(
                elapsed / HUDWaveMotion.coolDuration,
                1
            )
            presence = 1 - smoothstep(t)
            heat = pow(1 - t, 1.6)
            extent = pow(1 - min(t / 0.6, 1), 2)
            dotFlash = max(0, (t - 0.35) / 0.65)
            damp = exp(-elapsed / 0.12)
        }

        let level = Double(loudness) * damp
        let b = heat * (0.24 + 0.76 * level)
        let alpha = max(presence, heat)
        let half = (HUDWaveMotion.lineWidth / 2) * extent

        if half > 1.2 {
            let path = wavePath(
                cx: cx,
                cy: cy,
                half: half,
                amplitude: HUDWaveMotion.amplitude
                    * level * heat,
                time: date.timeIntervalSinceReferenceDate
            )

            // glow pass — the bloom
            context.drawLayer { layer in
                layer.addFilter(
                    .shadow(
                        color: color(
                            Self.midRGB,
                            0.65 * max(b, 0.35 * heat) * alpha
                        ),
                        radius: (8 + 22 * b) * 0.5
                    )
                )
                layer.stroke(
                    path,
                    with: .color(color(
                        goldMix(b),
                        (0.5 + 0.5 * min(b, 1)) * alpha
                    )),
                    style: StrokeStyle(
                        lineWidth: HUDWaveMotion.strokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            // hot core pass
            context.stroke(
                path,
                with: .color(color(
                    Self.paleRGB,
                    min(b, 1) * 0.85 * alpha
                )),
                style: StrokeStyle(
                    lineWidth: HUDWaveMotion.coreStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )

            if isLocked, phase == .burn {
                drawLockDots(
                    in: &context,
                    cx: cx,
                    cy: cy,
                    half: half,
                    brightness: b,
                    alpha: alpha
                )
            }
        }

        if dotFlash > 0 {
            drawOffDot(
                in: &context,
                cx: cx,
                cy: cy,
                strength: sin(.pi * min(dotFlash, 1)) * heat
            )
        }
    }

    private func drawStatic(
        in context: inout GraphicsContext,
        cx: CGFloat,
        cy: CGFloat
    ) {
        guard phase != .cool else {
            return
        }
        let level = phase == .burn ? Double(loudness) : 0
        let b = (phase == .ember ? 0.24 : 1.0)
            * (0.24 + 0.76 * level)
        var path = Path()
        path.move(
            to: CGPoint(x: cx - HUDWaveMotion.lineWidth / 2, y: cy)
        )
        path.addLine(
            to: CGPoint(x: cx + HUDWaveMotion.lineWidth / 2, y: cy)
        )
        context.stroke(
            path,
            with: .color(color(goldMix(b), 0.6 + 0.4 * min(b, 1))),
            style: StrokeStyle(
                lineWidth: HUDWaveMotion.strokeWidth,
                lineCap: .round
            )
        )

        if isLocked, phase == .burn {
            drawLockDots(
                in: &context,
                cx: cx,
                cy: cy,
                half: HUDWaveMotion.lineWidth / 2,
                brightness: b,
                alpha: 1
            )
        }
    }

    /// locked capture holds no key, so the line reads as bolted down: one
    /// small dot off each end, same gold, no motion of their own.
    private func drawLockDots(
        in context: inout GraphicsContext,
        cx: CGFloat,
        cy: CGFloat,
        half: CGFloat,
        brightness: Double,
        alpha: Double
    ) {
        let radius = Self.lockDotRadius
        let inset = half + Self.lockDotGap
        let fill = color(
            goldMix(brightness),
            (0.55 + 0.35 * min(brightness, 1)) * alpha
        )
        for x in [cx - inset, cx + inset] {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: x - radius,
                        y: cy - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                ),
                with: .color(fill)
            )
        }
    }

    private func wavePath(
        cx: CGFloat,
        cy: CGFloat,
        half: CGFloat,
        amplitude: CGFloat,
        time: TimeInterval
    ) -> Path {
        let segments = 48
        var path = Path()
        for i in 0...segments {
            let u = Double(i) / Double(segments)
            let x = cx - half + CGFloat(u) * half * 2
            let envelope = pow(sin(.pi * u), 1.4)
            let y = amplitude * envelope * (
                0.68 * sin(u * .pi * 4.4 - time * 8.2)
                    + 0.32 * sin(u * .pi * 8.2 + time * 5.1 + 1.3)
            )
            let point = CGPoint(x: x, y: cy + y)
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func drawOffDot(
        in context: inout GraphicsContext,
        cx: CGFloat,
        cy: CGFloat,
        strength: Double
    ) {
        let halo = 10 + 18 * strength
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: cx - halo,
                    y: cy - halo,
                    width: halo * 2,
                    height: halo * 2
                )
            ),
            with: .radialGradient(
                Gradient(colors: [
                    color(Self.midRGB, 0.35 * strength),
                    color(Self.midRGB, 0),
                ]),
                center: CGPoint(x: cx, y: cy),
                startRadius: 0,
                endRadius: halo
            )
        )

        let core = 1.8 + 0.8 * strength
        context.drawLayer { layer in
            layer.addFilter(
                .shadow(
                    color: color(Self.paleRGB, 0.9 * strength),
                    radius: 5
                )
            )
            layer.fill(
                Path(
                    ellipseIn: CGRect(
                        x: cx - core,
                        y: cy - core,
                        width: core * 2,
                        height: core * 2
                    )
                ),
                with: .color(color(Self.paleRGB, 0.95 * strength))
            )
        }
    }

    private func goldMix(_ b: Double) -> [Double] {
        let t = min(max(b, 0), 1)
        return [
            lerp(Self.deepRGB[0], Self.paleRGB[0], t),
            lerp(Self.deepRGB[1], Self.paleRGB[1], t),
            lerp(Self.deepRGB[2], Self.paleRGB[2], t),
        ]
    }

    private func color(_ rgb: [Double], _ alpha: Double) -> Color {
        Color(
            red: rgb[0] / 255,
            green: rgb[1] / 255,
            blue: rgb[2] / 255,
            opacity: min(max(alpha, 0), 1)
        )
    }

    private func lerp(
        _ a: Double,
        _ b: Double,
        _ t: Double
    ) -> Double {
        a + (b - a) * t
    }

    private func smoothstep(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
