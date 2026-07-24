import SwiftUI

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: DictationCoordinator.State
    @Published private(set) var commandFeedback: String?
    @Published private(set) var mode: DictationMode?
    @Published private(set) var levelRing = BrandLineLevelRing()
    @Published private(set) var waveTransitionStartedAt = Date()

    private let audioRecorder: AudioRecorder?
    private var levelSamplingTask: Task<Void, Never>?

    init(
        state: DictationCoordinator.State,
        audioRecorder: AudioRecorder?
    ) {
        self.state = state
        self.audioRecorder = audioRecorder
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
    }

    func showCommandFeedback(_ message: String) {
        commandFeedback = message
    }

    func clearCommandFeedback() {
        commandFeedback = nil
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
    }
}

struct HUDView: View {
    static let panelSize = CGSize(width: 196, height: 60)

    private static let capsuleSize = CGSize(width: 180, height: 44)

    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        Group {
            if let commandFeedback = viewModel.commandFeedback {
                feedbackPill(commandFeedback)
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
                }
            }
        }
        .frame(
            width: Self.panelSize.width,
            height: Self.panelSize.height
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
                levels: viewModel.levelRing,
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

    private func feedbackPill(_ message: String) -> some View {
        capsule {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HUDGold.pale)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
        }
    }

    private func gatePill(
        commandPreview: String,
        confirmationKeyName: String
    ) -> some View {
        capsule {
            VStack(alignment: .leading, spacing: 2) {
                Text(commandPreview)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HUDGold.pale)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(
                    "tap \(confirmationKeyName) to run · esc to cancel"
                )
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(HUDGold.pale.opacity(0.68))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
        }
    }

    private func capsule<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(
                width: Self.capsuleSize.width,
                height: Self.capsuleSize.height
            )
            .background {
                ZStack {
                    HUDGlassBackground()
                    HUDGold.black.opacity(0.22)
                }
                .clipShape(Capsule())
            }
            .overlay {
                Capsule()
                    .stroke(
                        HUDGold.mid.opacity(
                            isCommandMode ? 0.70 : 0.35
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: .black.opacity(0.30),
                radius: 7,
                y: 3
            )
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

private enum GoldWavePhase: Equatable {
    case recording
    case transcribing
}

private struct GoldSoundWave: View {
    private static let barCount = 7
    private static let barWidth: CGFloat = 3.5
    private static let barSpacing: CGFloat = 4
    private static let minimumHeight: CGFloat = 4
    private static let maximumHeight: CGFloat = 27
    private static let envelope: [CGFloat] = [
        0.48,
        0.68,
        0.86,
        1,
        0.86,
        0.68,
        0.48,
    ]

    let phase: GoldWavePhase
    let levels: BrandLineLevelRing
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
        let delayedLevels = BrandLineJointMapper.delayedLevels(
            in: levels,
            jointCount: Self.barCount
        )

        return delayedLevels.enumerated().map { index, level in
            let response = 0.18
                + 0.82 * CGFloat(Double(level).squareRoot())
            return Self.minimumHeight
                + (Self.maximumHeight - Self.minimumHeight)
                * Self.envelope[index]
                * response
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
