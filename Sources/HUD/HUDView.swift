import SwiftUI

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: DictationCoordinator.State
    @Published private(set) var commandFeedback: String?
    @Published private(set) var mode: DictationMode?
    @Published private(set) var levelRing = BrandLineLevelRing()
    @Published private(set) var lineTransitionStartedAt = Date()

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
            lineTransitionStartedAt = Date()
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
    static let panelSize = CGSize(width: 236, height: 68)

    private static let capsuleSize = CGSize(width: 220, height: 52)

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

    private var prewarmingPill: some View {
        capsule {
            HStack(spacing: 10) {
                BrandLinePrefix()
                subtleSpinner
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warming up")
    }

    private var subtleSpinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(BrandPalette.cream)
            .scaleEffect(0.72)
            .frame(width: 14, height: 14)
            .opacity(0.72)
    }

    private func livePill(
        phase: BrandLinePhase
    ) -> some View {
        capsule {
            BrandLine(
                phase: phase,
                mode: viewModel.mode,
                levels: viewModel.levelRing,
                transitionStartedAt:
                    viewModel.lineTransitionStartedAt
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            phase == .recording ? "Listening" : "Transcribing"
        )
    }

    private func feedbackPill(_ message: String) -> some View {
        capsule {
            HStack(spacing: 9) {
                BrandLinePrefix()

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandPalette.cream)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
    }

    private func gatePill(
        commandPreview: String,
        confirmationKeyName: String
    ) -> some View {
        capsule {
            HStack(spacing: 9) {
                BrandLinePrefix()

                VStack(alignment: .leading, spacing: 3) {
                    Text(commandPreview)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BrandPalette.cream)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(
                        "tap \(confirmationKeyName) to run · esc to cancel"
                    )
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(
                        BrandPalette.cream.opacity(0.62)
                    )
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
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
                Capsule()
                    .fill(BrandPalette.background.opacity(0.92))
            }
            .overlay {
                Capsule()
                    .stroke(
                        BrandPalette.cream.opacity(0.14),
                        lineWidth: 0.5
                    )
            }
            .shadow(
                color: .black.opacity(0.28),
                radius: 8,
                y: 3
            )
    }
}
