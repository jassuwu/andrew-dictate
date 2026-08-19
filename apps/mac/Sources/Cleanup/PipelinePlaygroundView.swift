import AppKit
import SwiftUI

@MainActor
final class PipelinePlaygroundViewModel: ObservableObject {
    @Published var input: String
    @Published private(set) var selection = PipelineSelection()
    @Published private(set) var results: [PipelineStageResult] = []
    @Published private(set) var isPolishing = false

    /// read live: a word you teach andrew after opening this window should
    /// show up in the next run, not the next launch.
    private let entriesProvider: @MainActor () -> [DictionaryEntry]
    private let polisher: TranscriptPolisher
    private var polishTask: Task<Void, Never>?
    /// bumped on every input or toggle change; a polish that finishes after a
    /// newer one started is stale and must not overwrite the newer answer.
    private var runGeneration = 0

    init(
        entries: @escaping @MainActor () -> [DictionaryEntry],
        polisher: TranscriptPolisher = FoundationModelPolisher(),
        input: String = PipelineSample.text
    ) {
        entriesProvider = entries
        self.polisher = polisher
        self.input = input
        recompute()
    }

    var isPolishAvailable: Bool {
        polisher.isAvailable
    }

    func toggle(_ stage: PipelineStage) {
        guard !stage.isAlwaysOn else {
            return
        }
        selection.toggle(stage)
        recompute()
    }

    func useSample() {
        input = PipelineSample.text
        recompute()
    }

    /// the deterministic half is pure and instant, so it runs on every
    /// keystroke. the model is not, so it waits for the typing to settle.
    func recompute() {
        runGeneration += 1
        let generation = runGeneration
        polishTask?.cancel()
        polishTask = nil

        let entries = entriesProvider()
        let cleaned = PipelineRun.throughCleaner(
            input,
            selection: selection,
            entries: entries
        )

        guard selection.polishEnabled else {
            isPolishing = false
            results = cleaned + [
                PipelineRun.polishResult(
                    input: PipelineRun.polishInput(from: cleaned),
                    output: nil,
                    isEnabled: false,
                    unavailableReason: nil
                ),
            ]
            return
        }

        let polishInput = PipelineRun.polishInput(from: cleaned)

        guard polisher.isAvailable else {
            isPolishing = false
            results = cleaned + [
                PipelineRun.polishResult(
                    input: polishInput,
                    output: nil,
                    isEnabled: true,
                    unavailableReason:
                        "needs macOS 26 and apple's on-device model"
                ),
            ]
            return
        }

        results = cleaned + [
            PipelineRun.polishResult(
                input: polishInput,
                output: nil,
                isEnabled: true,
                unavailableReason: nil
            ),
        ]
        isPolishing = true

        polishTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, generation == self.runGeneration else {
                return
            }

            var output: String?
            var failure: String?
            do {
                output = try await self.polisher.polish(
                    polishInput,
                    protectedTerms: entries.map(\.right)
                )
            } catch {
                failure = "the model couldn't polish this one"
            }

            guard !Task.isCancelled, generation == self.runGeneration else {
                return
            }

            self.isPolishing = false
            self.results = cleaned + [
                PipelineRun.polishResult(
                    input: polishInput,
                    output: output,
                    isEnabled: true,
                    unavailableReason: failure
                ),
            ]
        }
    }
}

/// the pipeline, made visible: type what you would have said, switch the
/// layers on and off, watch what each one hands to the next. nothing here
/// writes to settings — it is a what-if, not a control panel.
struct PipelinePlaygroundView: View {
    @ObservedObject var viewModel: PipelinePlaygroundViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                inputCard

                ForEach(viewModel.results) { result in
                    stageCard(result)
                }

                footer
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .background(BrandUI.windowBg)
        .foregroundStyle(BrandUI.textPrimary)
        .font(BrandUI.bodyFont)
        .brandTinted()
        .controlSize(.small)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("the pipeline")
                .font(BrandUI.titleFont)

            Text(
                "what happens between your voice and the page. "
                    + "you're standing in for the microphone."
            )
            .foregroundStyle(BrandUI.textSecondary)
        }
        .padding(.horizontal, 2)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                BrandSectionHeader("say something")

                Spacer()

                Button("use the example") {
                    viewModel.useSample()
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
            }
            .padding(.horizontal, 2)

            BrandCard {
                TextEditor(text: $viewModel.input)
                    .font(BrandUI.valueFont)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 66)
                    .onChange(of: viewModel.input) { _, _ in
                        viewModel.recompute()
                    }
                    .accessibilityLabel("test transcript")
            }
        }
    }

    private func stageCard(_ result: PipelineStageResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                BrandSectionHeader(result.stage.title)

                if result.stage.isAlwaysOn {
                    Text("always on")
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)
                }

                Spacer()

                if result.stage == .polish, viewModel.isPolishing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }

                if !result.stage.isAlwaysOn {
                    Toggle("", isOn: Binding(
                        get: { result.isEnabled },
                        set: { _ in viewModel.toggle(result.stage) }
                    ))
                    .labelsHidden()
                    .brandToggleStyle()
                    .accessibilityLabel(result.stage.title)
                }
            }
            .padding(.horizontal, 2)

            BrandCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.stage.summary)
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)

                    Text(result.output.isEmpty ? " " : result.output)
                        .font(BrandUI.valueFont)
                        .foregroundStyle(
                            result.isEnabled
                                ? BrandUI.textPrimary
                                : BrandUI.textSecondary
                        )
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )

                    stageNote(result)
                }
            }
        }
    }

    @ViewBuilder
    private func stageNote(_ result: PipelineStageResult) -> some View {
        if let reason = result.unavailableReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(BrandUI.gold)
        } else if !result.isEnabled {
            Text("off — the text passes straight through")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        } else if result.stage == .polish, viewModel.isPolishing {
            Text("thinking…")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        } else if !result.changedAnything, result.stage != .transcription {
            Text("nothing to change here")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "these switches are a what-if — they don't change your "
                    + "settings. cleanup can't actually be turned off: "
                    + "it's where your dictionary and spoken punctuation live."
            )
            .font(.caption)
            .foregroundStyle(BrandUI.textSecondary)

            if viewModel.isPolishAvailable,
               settings.cleanupMode == .off {
                Button("turn ai cleanup on for real") {
                    settings.cleanupMode = .on
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
            }
        }
        .padding(.horizontal, 2)
    }
}

@MainActor
final class PipelinePlaygroundWindowController: NSWindowController {
    init(
        entries: @escaping @MainActor () -> [DictionaryEntry],
        settings: AppSettings
    ) {
        let viewModel = PipelinePlaygroundViewModel(entries: entries)
        let rootView = PipelinePlaygroundView(
            viewModel: viewModel,
            settings: settings
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "the pipeline"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.setContentSize(NSSize(width: 660, height: 680))
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
