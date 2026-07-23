import SwiftUI

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state: DictationCoordinator.State
    @Published private(set) var commandFeedback: String?
    @Published private(set) var mode: DictationMode?

    private let audioRecorder: AudioRecorder?

    init(
        state: DictationCoordinator.State,
        audioRecorder: AudioRecorder?
    ) {
        self.state = state
        self.audioRecorder = audioRecorder
    }

    var currentLevel: Float {
        audioRecorder?.currentLevel ?? 0
    }

    func update(
        state: DictationCoordinator.State,
        mode: DictationMode? = nil
    ) {
        self.state = state
        if let mode {
            self.mode = mode
        } else if state == .idle || state == .prewarming {
            self.mode = nil
        }
        commandFeedback = nil
    }

    func showCommandFeedback(_ message: String) {
        commandFeedback = message
    }

    func clearCommandFeedback() {
        commandFeedback = nil
    }
}

struct HUDView: View {
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        Group {
            if let commandFeedback = viewModel.commandFeedback {
                statusPill {
                    Image(systemName: "terminal")
                        .opacity(0.75)
                    Text(commandFeedback)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                switch viewModel.state {
                case .idle:
                    EmptyView()
                case .prewarming:
                    statusPill {
                        subtleSpinner
                        Text("warming up")
                    }
                case .recording:
                    statusPill {
                        commandModeMarker
                        Text("listening")
                        TimelineView(
                            .periodic(from: .now, by: 1.0 / 30.0)
                        ) { _ in
                            LevelMeter(level: viewModel.currentLevel)
                        }
                    }
                case .transcribing:
                    statusPill {
                        commandModeMarker
                        subtleSpinner
                        Text("transcribing")
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: 220, height: 58)
    }

    private var subtleSpinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.primary)
            .scaleEffect(0.75)
            .frame(width: 14, height: 14)
            .opacity(0.75)
    }

    @ViewBuilder
    private var commandModeMarker: some View {
        if viewModel.mode == .command {
            Text(">")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .opacity(0.65)
                .accessibilityLabel("command mode")
        }
    }

    private func statusPill<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 9, content: content)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .frame(
                        width: 3,
                        height: barHeight(at: index)
                    )
            }
        }
        .frame(width: 25, height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int) -> CGFloat {
        let maximumHeight: CGFloat
        switch index {
        case 0, 4:
            maximumHeight = 10
        case 1, 3:
            maximumHeight = 15
        default:
            maximumHeight = 18
        }

        let threshold = Float(index) * 0.08
        let scaledLevel = max(
            0,
            min((level - threshold) / (1 - threshold), 1)
        )
        return 4 + CGFloat(scaledLevel) * (maximumHeight - 4)
    }
}
