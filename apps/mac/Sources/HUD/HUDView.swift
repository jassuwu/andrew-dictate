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

/// what sits under the lamp line so it survives a light background. a bare
/// gold line is a lamp on black and an underline on a white page.
///
/// the HUD ships `.painted` (2026-09-22), standing on `.smoke`. the others
/// remain for the lamp lab, where they are the comparison it was chosen
/// against — so only the debug build, which has the lab, carries them.
enum LampGround: String, CaseIterable {
    #if DEBUG
    /// today: the line and its bloom on nothing
    case bare
    #endif
    /// a blurred dark stroke under the line — invisible on black, a faint
    /// smoke on white. the subtitle trick.
    case smoke
    #if DEBUG
    /// a sliver of Liquid Glass behind the line: the same capsule the text
    /// pill uses, so one can morph into the other
    case glass
    /// the line itself is the glass: a wavy ribbon of Liquid Glass with the
    /// gold light shining up through it, smoke under both
    case ribbon
    /// the ribbon with the light *inside* it: a bright gold fill in the
    /// ribbon's own outline, under regular glass, which refracts it
    case ribbonLit
    /// the same lit ribbon under clear glass, which lets more of the light
    /// through than regular
    case ribbonClear
    #endif
    /// the tube drawn by hand: translucent tan body, pale rim on top, shade
    /// below, halo and smoke. no Liquid Glass, so it looks the same in the
    /// panel as in the lab — Liquid Glass draws dimmed in a window that is
    /// not key, and the panel never is (ADR 0042).
    case painted

    /// the one that ships: the drawn tube (2026-09-22). the tinted Liquid
    /// Glass ribbon is the look it copies; it only has it in a key window.
    static let shipped: LampGround = .painted

    var isRibbon: Bool {
        switch self {
        case .painted:
            return true
        case .smoke:
            return false
        #if DEBUG
        case .ribbon, .ribbonLit, .ribbonClear:
            return true
        case .bare, .glass:
            return false
        #endif
        }
    }

    /// a light in the ribbon's outline under the glass
    var litInside: Bool {
        #if DEBUG
        return self == .ribbonLit || self == .ribbonClear
        #else
        return false
        #endif
    }

    /// no glass effect at all: the canvas draws the tube
    var drawsGlass: Bool {
        self == .painted
    }
}

#if DEBUG
/// what only the lab asks of a ground: its name, which ones to audition,
/// and how the Liquid Glass ones are glassed.
extension LampGround: Identifiable {
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bare: "bare line"
        case .smoke: "smoke"
        case .glass: "glass sliver"
        case .ribbon: "ribbon, tinted"
        case .ribbonLit: "ribbon, lit inside"
        case .ribbonClear: "clear, lit inside"
        case .painted: "glass, drawn"
        }
    }

    /// what the lab shows and the live switch accepts: the ribbons. the
    /// line, smoke and sliver were the audition the ribbon won.
    static let candidates: [LampGround] = [.ribbon, .ribbonClear, .painted]

    /// carries a glass ID, so it can morph into the pill
    var isGlass: Bool {
        self == .glass || isRibbon
    }

    var glass: Glass {
        self == .ribbonLit || self == .ribbon ? .regular : .clear
    }
}
#endif

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
    #if DEBUG
    /// development only: a voice for the rehearsal. when set, the sampler
    /// reads this instead of the recorder.
    var rehearsalLevel: Float?
    #endif

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

    /// the glass morphs only inside an animation, so every swap of what is
    /// on the stage goes through this. reduce motion: snap.
    static var morph: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .snappy(duration: 0.36, extraBounce: 0.1)
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
        withAnimation(Self.morph) {
            self.state = state
            feedbackMessage = nil
            presentationGeneration += 1
        }
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
        withAnimation(Self.morph) {
            feedbackMessage = message
            presentationGeneration += 1
        }
    }

    func clearFeedback() {
        withAnimation(Self.morph) {
            feedbackMessage = nil
            presentationGeneration += 1
        }
    }

    func updateLayout(_ layout: HUDLayout) {
        guard layout != self.layout else {
            return
        }
        self.layout = layout
    }

    /// the panel and this view must agree on the stage; both read the
    /// engine, this one through the panel's screen width when it is set.
    @Published private(set) var stageSize = HUDLayoutEngine.stageSize(
        screenWidth: 1_440
    )

    func updateStage(screenWidth: CGFloat) {
        let size = HUDLayoutEngine.stageSize(screenWidth: screenWidth)
        guard size != stageSize else {
            return
        }
        stageSize = size
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

    /// the mic, unless a debug build is rehearsing the lamp.
    private var currentLevel: Float {
        #if DEBUG
        if let rehearsalLevel {
            return rehearsalLevel
        }
        #endif
        return audioRecorder?.currentLevel ?? 0
    }

    private func sampleCurrentLevel(interval: Double) {
        let shaped = WaveLevelShaper.shape(currentLevel)
        let attack = 1 - exp(-interval / 0.040)
        let release = 1 - exp(-interval / 0.200)
        let gain = shaped > loudness ? attack : release
        loudness += (shaped - loudness) * Float(gain)
    }
}

/// the stage: one glass container holding whichever of the two glass shapes
/// the moment calls for — the ribbon, or the line of text. both carry the
/// same glass ID, so a swap is a morph: the ribbon swells into the pill the
/// way Spotlight's field liquidates open (ADR 0042).
struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    @Namespace private var glassNamespace
    private static let glassID = "lamp"

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ZStack {
                if let feedbackMessage = viewModel.feedbackMessage {
                    HUDTextPill(
                        message: feedbackMessage,
                        lineCount: viewModel.layout.lineCount,
                        size: viewModel.layout.size
                    )
                    .glassEffectID(Self.glassID, in: glassNamespace)
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
        }
        .frame(
            width: viewModel.stageSize.width,
            height: viewModel.stageSize.height
        )
        // the panel never becomes key — it must not steal the keyboard
        // from the app being dictated into — and glass in an inactive
        // window is drawn dimmed and desaturated. this tells the glass it
        // is active anyway, which is what a lamp is.
        .environment(\.appearsActive, true)
    }

    private func lampLine(phase: GoldRippleLine.Phase) -> some View {
        LampLine(
            phase: phase,
            loudness: viewModel.loudness,
            startedAt: viewModel.waveTransitionStartedAt,
            isLocked: viewModel.isRecordingLocked,
            ground: LampGround.shipped,
            glassID: Self.glassID,
            glassNamespace: glassNamespace
        )
        .frame(
            width: HUDLayoutEngine.waveSize.width,
            height: HUDLayoutEngine.waveSize.height
        )
    }
}

/// the lamp's one line of text, on real Liquid Glass.
struct HUDTextPill: View {
    let message: String
    let lineCount: Int
    let size: CGSize
    /// dark glass: gold-tinted glass went light over a light page and took
    /// the pale gold text with it (lamp lab, 2026-09-21). the lab can still
    /// try the gold.
    static let darkTint = BrandUI.black.opacity(0.35)
    var glassTint: Color = HUDTextPill.darkTint

    var body: some View {
        Text(message)
            // the lamp phases already name themselves; the pill is the one
            // that carries the words, so it needs the same identity.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .font(Font(HUDLayoutEngine.primaryFont))
            .foregroundStyle(BrandUI.goldPale)
            .lineLimit(lineCount)
            .lineSpacing(HUDLayoutEngine.wrappedLineSpacing)
            .truncationMode(.tail)
            .padding(
                .horizontal,
                HUDLayoutEngine.horizontalPadding
            )
            .frame(width: size.width, height: size.height)
            // real Liquid Glass: it samples whatever is behind the panel
            // and draws its own edge, which retired the NSVisualEffectView
            // + maskImage workaround and the hand-drawn gold stroke. proven
            // over a borderless non-activating panel by a screenshot spike
            // before betting the HUD on it (ADR 0037). tinted toward the
            // brand black, not gold: the pill carries every exceptional
            // sentence, and gold-on-gold vanished over a white document.
            .glassEffect(
                .regular.tint(glassTint),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
    }
}


/// the lamp line plus whatever grounds it. the glass sliver is a background
/// so the bloom, drawn by the canvas, spills over the capsule's edge instead
/// of being clipped by it.
struct LampLine: View {
    let phase: GoldRippleLine.Phase
    let loudness: Float
    let startedAt: Date
    var isLocked = false
    var ground: LampGround = .shipped
    /// set both to let the sliver morph into another glass shape in the
    /// same `GlassEffectContainer`
    var glassID: String?
    var glassNamespace: Namespace.ID?

    /// thinner than the glass wants, longer to make up for it: the ribbon
    /// has to stay a line, not a worm
    static let ribbonThickness: CGFloat = 6
    static let ribbonLength: CGFloat = 112

    var body: some View {
        GoldRippleLine(
            phase: phase,
            loudness: loudness,
            startedAt: startedAt,
            isLocked: isLocked,
            ground: ground.isRibbon ? .smoke : ground,
            filament: !ground.isRibbon,
            innerLight: ground.litInside,
            drawnGlass: ground.drawsGlass,
            lineWidth: ground.isRibbon
                ? Self.ribbonLength
                : HUDWaveMotion.lineWidth
        )
        // the drawn tube is all canvas; only the lab's grounds put glass
        // behind or over it.
        #if DEBUG
        .background {
            if ground == .glass {
                sliver
            }
        }
        .overlay {
            if ground.isRibbon, !ground.drawsGlass {
                ribbon
            }
        }
        #endif
    }

    #if DEBUG
    static let glassSize = CGSize(
        width: HUDWaveMotion.lineWidth + 36,
        height: 26
    )

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// the glass rides the same pose as the line under it, every frame
    private var ribbon: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)
        ) { timeline in
            let elapsed = max(
                0,
                timeline.date.timeIntervalSince(startedAt)
            )
            let pose = LampPose.at(
                phase: phase,
                elapsed: elapsed,
                date: timeline.date
            )
            let level = Double(loudness) * pose.damp
            let alpha = max(pose.presence, pose.heat)
            // the same brightness curve the filament had: ember dim, burn
            // lit, loud hot — now it is the glass that carries it
            let brightness = ground.litInside
                ? pose.heat * (0.45 + 0.55 * level)
                : pose.heat * (0.24 + 0.76 * level)
            let shape = WaveRibbonShape(
                half: (Self.ribbonLength / 2) * pose.extent,
                amplitude: HUDWaveMotion.amplitude * level * pose.heat,
                time: timeline.date.timeIntervalSinceReferenceDate,
                thickness: Self.ribbonThickness
            )
            // lit inside: the fill under the glass is the light, so the
            // tint only warms the glass instead of painting it
            let tint = GoldRippleLine.tint(brightness: brightness)
                .opacity(
                    ground.litInside
                        ? 0.06 + 0.30 * min(brightness, 1)
                        : 0.12 + 0.70 * min(brightness, 1)
                )
            let half = (Self.ribbonLength / 2) * pose.extent
            ZStack {
                glassed(
                    Color.clear.glassEffect(
                        ground.glass.tint(tint),
                        in: shape
                    ),
                    id: glassID
                )
                // locked: a glass bead off each end, the same light. it
                // shares the container, so it blends into the ribbon's end
                // the way the ribbon blends into the pill.
                if isLocked, phase == .burn {
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Color.clear
                            .frame(
                                width: Self.ribbonThickness,
                                height: Self.ribbonThickness
                            )
                            .glassEffect(
                                ground.glass.tint(tint),
                                in: Circle()
                            )
                            .offset(
                                x: side * (half + Self.lockBeadGap)
                            )
                    }
                }
            }
            .opacity(alpha)
        }
    }

    static let lockBeadGap: CGFloat = 9


    @ViewBuilder
    private func glassed(_ view: some View, id: String?) -> some View {
        if let id, let glassNamespace {
            view.glassEffectID(id, in: glassNamespace)
        } else {
            view
        }
    }

    @ViewBuilder
    private var sliver: some View {
        let glass = Color.clear
            .frame(
                width: Self.glassSize.width,
                height: Self.glassSize.height
            )
            .glassEffect(
                .regular.tint(BrandUI.gold.opacity(0.10)),
                in: Capsule()
            )
        if let glassID, let glassNamespace {
            glass.glassEffectID(glassID, in: glassNamespace)
        } else {
            glass
        }
    }
    #endif
}

/// where the lamp is in its life, as numbers: the same pose drives the gold
/// line and, in the ribbon variant, the glass shape over it.
struct LampPose {
    var heat = 0.0
    var presence = 0.0
    var extent = 1.0
    var dotFlash = 0.0
    var damp = 1.0

    static func at(
        phase: GoldRippleLine.Phase,
        elapsed: TimeInterval,
        date: Date
    ) -> LampPose {
        var pose = LampPose()
        switch phase {
        case .ember:
            let breathe = sin(
                date.timeIntervalSinceReferenceDate
                    * .pi * 2 / 2.8
            )
            pose.heat = 0.20 + 0.08 * breathe
            pose.presence = 1
            pose.damp = 0
        case .burn:
            let t = min(elapsed / HUDWaveMotion.igniteDuration, 1)
            pose.presence = min(t / 0.6, 1)
            pose.extent = 1 - pow(1 - t, 3)
            pose.heat = t < 0.75
                ? smoothstep(t / 0.75) * 1.12
                : lerp(1.12, 1, (t - 0.75) / 0.25)
        case .cool:
            let t = min(elapsed / HUDWaveMotion.coolDuration, 1)
            pose.presence = 1 - smoothstep(t)
            pose.heat = pow(1 - t, 1.6)
            pose.extent = pow(1 - min(t / 0.6, 1), 2)
            pose.dotFlash = max(0, (t - 0.35) / 0.65)
            pose.damp = exp(-elapsed / 0.12)
        }
        return pose
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func smoothstep(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

#if DEBUG
/// the wave as a shape, so Liquid Glass can take its outline: the stroked
/// path of the same line the canvas draws. the lab's glass ribbons only.
struct WaveRibbonShape: Shape {
    let half: CGFloat
    let amplitude: CGFloat
    let time: TimeInterval
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        GoldRippleLine.wavePath(
            cx: rect.midX,
            cy: rect.midY,
            half: max(half, 0.5),
            amplitude: amplitude,
            time: time
        )
        .strokedPath(
            StrokeStyle(
                lineWidth: thickness,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}
#endif

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
    /// only `.smoke` is drawn here: the rest of a ground is `LampLine`'s.
    var ground: LampGround
    /// false when a glass ribbon is the lamp: no line and no hot core, only
    /// the smoke, a halo that spills light by loudness, the lock dots and
    /// the off-dot. the glass over it carries the colour.
    var filament = true
    /// with `filament` off: a bright fill in the ribbon's own width under
    /// the glass, plus a hotter core — the tube lit from inside
    var innerLight = false
    /// with `filament` off: paint the glass tube itself
    var drawnGlass = false
    var lineWidth: CGFloat = HUDWaveMotion.lineWidth

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// the smoke: wide, soft, dark. black on black is nothing; on a page it
    /// is the shadow a subtitle carries.
    private static let smokeWidth: CGFloat = 12
    private static let smokeBlur: CGFloat = 7
    private static let smokeAlpha = 0.42

    /// derived from the line's own metrics so the pins scale with it —
    /// a hair thicker than the hot core, set just off each end.
    private static let lockDotRadius =
        HUDWaveMotion.coreStrokeWidth * 1.35
    private static let lockDotGap =
        HUDWaveMotion.strokeWidth * 2.2

    // the lamp burns the brand's gold, not a second copy of it.
    private static let paleRGB = BrandUI.goldPaleRGB
    private static let midRGB = BrandUI.goldRGB
    private static let deepRGB = BrandUI.goldDeepRGB

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

        let pose = LampPose.at(
            phase: phase,
            elapsed: elapsed,
            date: date
        )
        let heat = pose.heat
        let presence = pose.presence
        let extent = pose.extent
        let dotFlash = pose.dotFlash
        let damp = pose.damp

        let level = Double(loudness) * damp
        let b = heat * (0.24 + 0.76 * level)
        let alpha = max(presence, heat)
        let half = (lineWidth / 2) * extent

        if half > 1.2 {
            let path = Self.wavePath(
                cx: cx,
                cy: cy,
                half: half,
                amplitude: HUDWaveMotion.amplitude
                    * level * heat,
                time: date.timeIntervalSinceReferenceDate
            )

            if ground == .smoke {
                drawSmoke(
                    in: &context,
                    path: path,
                    alpha: alpha * (0.6 + 0.4 * min(heat, 1))
                )
            }

            if filament {
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
            } else {
                // halo pass — the light the glass spills
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 6 + 6 * min(b, 1)))
                    layer.stroke(
                        path,
                        with: .color(color(
                            goldMix(b),
                            (innerLight ? 0.40 : 0.55) * min(b, 1) * alpha
                        )),
                        style: StrokeStyle(
                            lineWidth: LampLine.ribbonThickness + 8,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }

                if drawnGlass {
                    drawGlassTube(
                        in: &context,
                        path: path,
                        brightness: b,
                        level: level,
                        alpha: alpha
                    )
                }

                if innerLight {
                    // the light under the glass: full ribbon width, gold
                    // going pale with brightness, a white-hot core when
                    // loud. the glass refracts it into a lit tube.
                    let glow = min(heat * (0.45 + 0.55 * level), 1)
                    context.stroke(
                        path,
                        with: .color(color(
                            goldMix(0.35 + 0.65 * glow),
                            (0.45 + 0.55 * glow) * alpha
                        )),
                        style: StrokeStyle(
                            lineWidth: LampLine.ribbonThickness,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    context.stroke(
                        path,
                        with: .color(color(
                            [255, 250, 225],
                            (0.35 + 0.65 * glow) * min(level + 0.35, 1)
                                * alpha
                        )),
                        style: StrokeStyle(
                            lineWidth: LampLine.ribbonThickness * 0.45,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }

            if isLocked, phase == .burn, filament || drawnGlass {
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
            if ground == .smoke {
                let strength = sin(.pi * min(dotFlash, 1)) * heat
                var dot = Path()
                dot.move(to: CGPoint(x: cx - 1, y: cy))
                dot.addLine(to: CGPoint(x: cx + 1, y: cy))
                drawSmoke(in: &context, path: dot, alpha: strength)
            }
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
        path.move(to: CGPoint(x: cx - lineWidth / 2, y: cy))
        path.addLine(to: CGPoint(x: cx + lineWidth / 2, y: cy))
        if ground == .smoke {
            drawSmoke(in: &context, path: path, alpha: 1)
        }
        if drawnGlass {
            drawGlassTube(
                in: &context,
                path: path,
                brightness: b,
                level: level,
                alpha: 1
            )
        }
        guard filament else {
            return
        }
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
                half: lineWidth / 2,
                brightness: b,
                alpha: 1
            )
        }
    }

    /// the tube, by hand. what tinted Liquid Glass looks like in a key
    /// window: a translucent tan body that takes the backdrop through it,
    /// a pale rim along the top, a shade along the bottom, a faint outline
    /// so it holds on white, and a soft core that comes up with the voice.
    private func drawGlassTube(
        in context: inout GraphicsContext,
        path: Path,
        brightness b: Double,
        level: Double,
        alpha: Double
    ) {
        let t = LampLine.ribbonThickness
        let lit = min(max(b, 0), 1)
        let tube = StrokeStyle(lineWidth: t, lineCap: .round, lineJoin: .round)
        let tubeShape = path.strokedPath(tube)

        // outline: barely there on black, the edge on white
        context.stroke(
            path,
            with: .color(.black.opacity(0.14 * alpha)),
            style: StrokeStyle(lineWidth: t + 1.4, lineCap: .round, lineJoin: .round)
        )
        // body: tan going pale as it lights
        context.stroke(
            path,
            with: .color(color(goldMix(0.40 + 0.40 * lit), (0.42 + 0.28 * lit) * alpha)),
            style: tube
        )
        // shade along the bottom, inside the tube
        context.drawLayer { layer in
            layer.clip(to: tubeShape)
            layer.addFilter(.blur(radius: 1.0))
            layer.stroke(
                path.offsetBy(dx: 0, dy: t * 0.28),
                with: .color(color(Self.deepRGB, 0.34 * alpha)),
                style: StrokeStyle(lineWidth: t * 0.62, lineCap: .round, lineJoin: .round)
            )
        }
        // rim along the top, and a thinner echo along the bottom
        context.drawLayer { layer in
            layer.clip(to: tubeShape)
            layer.addFilter(.blur(radius: 0.45))
            layer.stroke(
                path.offsetBy(dx: 0, dy: -(t / 2 - 1.0)),
                with: .color(color(Self.paleRGB, (0.50 + 0.40 * lit) * alpha)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
            layer.stroke(
                path.offsetBy(dx: 0, dy: t / 2 - 0.7),
                with: .color(.white.opacity(0.16 * alpha)),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
            )
        }
        // the core: the light inside, by the voice
        context.drawLayer { layer in
            layer.clip(to: tubeShape)
            layer.addFilter(.blur(radius: 1.4))
            layer.stroke(
                path,
                with: .color(color(Self.paleRGB, (0.10 + 0.55 * min(level, 1)) * lit * alpha)),
                style: StrokeStyle(lineWidth: t * 0.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawSmoke(
        in context: inout GraphicsContext,
        path: Path,
        alpha: Double
    ) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: Self.smokeBlur))
            layer.stroke(
                path,
                with: .color(.black.opacity(Self.smokeAlpha * alpha)),
                style: StrokeStyle(
                    lineWidth: Self.smokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
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

    static func wavePath(
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

    #if DEBUG
    /// the lamp's colour at a brightness, for anything outside the canvas
    /// that wants to glow the same gold — the glass ribbon's tint.
    static func tint(brightness b: Double) -> Color {
        let t = min(max(b, 0), 1)
        return Color(
            red: lerpValue(deepRGB[0], paleRGB[0], t) / 255,
            green: lerpValue(deepRGB[1], paleRGB[1], t) / 255,
            blue: lerpValue(deepRGB[2], paleRGB[2], t) / 255
        )
    }

    private static func lerpValue(
        _ a: Double,
        _ b: Double,
        _ t: Double
    ) -> Double {
        a + (b - a) * t
    }
    #endif

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
