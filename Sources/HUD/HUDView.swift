import SwiftUI

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: DictationCoordinator.State
    @Published private(set) var commandFeedback: String?
    @Published private(set) var mode: DictationMode?
    @Published private(set) var layout: HUDLayout
    @Published private(set) var presentationGeneration = 0
    @Published private(set) var levelRing = BrandLineLevelRing()
    @Published private(set) var displayLevels: [Float] = Array(
        repeating: 0,
        count: GoldSoundWave.barCount
    )

    private var waveSmoother = WaveDisplaySmoother(
        barCount: GoldSoundWave.barCount
    )
    @Published private(set) var waveTransitionStartedAt = Date()

    private let audioRecorder: AudioRecorder?
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
        if let commandFeedback {
            return .text(
                primary: commandFeedback,
                secondary: nil
            )
        }

        switch state {
        case .idle, .recording, .transcribing:
            return .wave
        case .prewarming:
            return .prewarming
        case let .gatePending(
            commandPreview,
            confirmationKeyName
        ):
            return .text(
                primary: commandPreview,
                secondary:
                    "tap \(confirmationKeyName) to run · esc to cancel"
            )
        case let .transcriptFlash(transcript):
            return .text(primary: transcript, secondary: nil)
        }
    }

    func update(
        state: DictationCoordinator.State,
        mode: DictationMode? = nil
    ) {
        let previousState = self.state

        if state != previousState {
            waveTransitionStartedAt = Date()
        }

        if let mode {
            self.mode = mode
        } else if state == .idle || state == .prewarming {
            self.mode = nil
        }

        configureLevelSampling(
            for: state,
            previousState: previousState
        )
        self.state = state
        commandFeedback = nil
        presentationGeneration += 1
    }

    func showCommandFeedback(_ message: String) {
        commandFeedback = message
        presentationGeneration += 1
    }

    func clearCommandFeedback() {
        commandFeedback = nil
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
                levelRing.reset()
                waveSmoother.reset()
                displayLevels = waveSmoother.display
            }
            return
        }

        guard previousState != .recording else {
            return
        }

        levelRing.reset()
        sampleCurrentLevel()
        levelSamplingTask?.cancel()
        levelSamplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }

                self?.sampleCurrentLevel()
            }
        }
    }

    private func sampleCurrentLevel() {
        var updatedRing = levelRing
        updatedRing.push(audioRecorder?.currentLevel ?? 0)
        levelRing = updatedRing

        let delayed = BrandLineJointMapper.delayedLevels(
            in: updatedRing,
            jointCount: GoldSoundWave.barCount
        )
        displayLevels = waveSmoother.update(
            with: delayed.map(WaveLevelShaper.shape)
        )
    }
}

struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        ZStack {
            Group {
                if let commandFeedback = viewModel.commandFeedback {
                    textPill(commandFeedback)
                } else {
                    switch viewModel.state {
                    case .idle:
                        EmptyView()
                    case .prewarming:
                        prewarmingPill
                    case .recording:
                        livePill(phase: .recording)
                    case .transcribing:
                        livePill(phase: .transcribing)
                    case let .gatePending(
                        commandPreview,
                        confirmationKeyName
                    ):
                        gatePill(
                            commandPreview: commandPreview,
                            confirmationKeyName: confirmationKeyName
                        )
                    case let .transcriptFlash(transcript):
                        textPill(transcript)
                    }
                }
            }
            .id(viewModel.presentationGeneration)
            .transition(
                .opacity.combined(with: .scale(scale: 0.94))
            )
        }
        .animation(
            reduceMotion
                ? nil
                : .snappy(duration: 0.32, extraBounce: 0.12),
            value: viewModel.presentationGeneration
        )
        .frame(
            width: viewModel.layout.size.width,
            height: viewModel.layout.size.height
        )
    }

    private var isCommandMode: Bool {
        viewModel.mode == .command
    }

    private var prewarmingPill: some View {
        capsule {
            ProgressView()
                .controlSize(.small)
                .tint(HUDGold.mid)
                .scaleEffect(0.72)
                .frame(width: 14, height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warming up")
    }

    private func livePill(
        phase: GoldWavePhase
    ) -> some View {
        capsule {
            GoldSoundWave(
                phase: phase,
                levels: viewModel.displayLevels,
                transitionStartedAt:
                    viewModel.waveTransitionStartedAt,
                isCommandMode: isCommandMode
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            phase == .recording ? "Listening" : "Transcribing"
        )
    }

    private func textPill(_ message: String) -> some View {
        capsule {
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
        }
    }

    private func gatePill(
        commandPreview: String,
        confirmationKeyName: String
    ) -> some View {
        capsule {
            VStack(alignment: .leading, spacing: 2) {
                Text(commandPreview)
                    .font(Font(HUDLayoutEngine.primaryFont))
                    .foregroundStyle(HUDGold.pale)
                    .lineLimit(viewModel.layout.lineCount)
                    .lineSpacing(HUDLayoutEngine.wrappedLineSpacing)
                    .truncationMode(.tail)

                Text(
                    "tap \(confirmationKeyName) to run · esc to cancel"
                )
                .font(Font(HUDLayoutEngine.secondaryFont))
                .foregroundStyle(HUDGold.pale.opacity(0.68))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(
                .horizontal,
                HUDLayoutEngine.horizontalPadding
            )
        }
    }

    private func capsule<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
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
                        HUDGold.mid.opacity(
                            isCommandMode ? 0.70 : 0.35
                        ),
                        lineWidth: 1
                    )
            }
    }
}

private enum HUDGold {
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
    static let commandPale = Color(
        red: 255.0 / 255.0,
        green: 246.0 / 255.0,
        blue: 201.0 / 255.0
    )
    static let black = Color(
        red: 11.0 / 255.0,
        green: 11.0 / 255.0,
        blue: 13.0 / 255.0
    )
}

enum GoldWavePhase: Equatable {
    case recording
    case transcribing
}

struct GoldSoundWave: View {
    static let barCount = 11
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 3
    private static let minimumHeight: CGFloat = 3
    private static let maximumHeight: CGFloat = 26
    /// smooth cosine bell, center-weighted like the badge's flanking waves
    private static let envelope: [CGFloat] = (0..<barCount).map { index in
        let position = (CGFloat(index) + 0.5) / CGFloat(barCount)
        return 0.30 + 0.70 * sin(.pi * position)
    }

    let phase: GoldWavePhase
    let levels: [Float]
    let transitionStartedAt: Date
    let isCommandMode: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: reduceMotion || phase != .transcribing
            )
        ) { timeline in
            let heights = barHeights(at: timeline.date)

            HStack(spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(barGradient)
                        .frame(
                            width: Self.barWidth,
                            height: heights[index]
                        )
                }
            }
            .frame(height: Self.maximumHeight)
        }
        .accessibilityHidden(true)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: isCommandMode
                ? [HUDGold.commandPale, HUDGold.mid]
                : [HUDGold.pale, HUDGold.deep],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func barHeights(at date: Date) -> [CGFloat] {
        let liveHeights = levelScaledHeights()
        guard phase == .transcribing, !reduceMotion else {
            return liveHeights
        }

        let elapsed = max(
            0,
            date.timeIntervalSince(transitionStartedAt)
        )
        let linearProgress = min(CGFloat(elapsed / 0.42), 1)
        let easedProgress = linearProgress * linearProgress
            * (3 - 2 * linearProgress)

        return liveHeights.enumerated().map { index, liveHeight in
            let rippleHeight = autonomousHeight(
                for: index,
                elapsed: elapsed
            )
            return liveHeight
                + (rippleHeight - liveHeight) * easedProgress
        }
    }

    private func levelScaledHeights() -> [CGFloat] {
        (0..<Self.barCount).map { index in
            let level = index < levels.count ? CGFloat(levels[index]) : 0
            return Self.minimumHeight
                + (Self.maximumHeight - Self.minimumHeight)
                * Self.envelope[index]
                * level
        }
    }

    private func autonomousHeight(
        for index: Int,
        elapsed: TimeInterval
    ) -> CGFloat {
        let distanceFromCenter = abs(index - Self.barCount / 2)
        let ripple = 0.50 + 0.16 * sin(
            elapsed * .pi * 2 / 1.35
                - Double(distanceFromCenter) * 0.72
        )
        return Self.minimumHeight
            + (Self.maximumHeight - Self.minimumHeight)
            * Self.envelope[index]
            * CGFloat(ripple)
    }
}
