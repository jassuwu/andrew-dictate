import SwiftUI

/// the cleanup pipeline, as a conveyor: three stages, an arrow between each,
/// a switch on the ones that have one, and under every stage the text as
/// it leaves it — your last dictation, or a sample until there is one.
/// nothing decorative: every mark on it is a stage, a switch, or a word.
struct PipelineView: View {
    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var run: PipelinePlaygroundViewModel

    init(coordinator: DictationCoordinator, settings: AppSettings) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: settings)
        let store = coordinator.dictionaryStore
        _run = StateObject(
            wrappedValue: PipelinePlaygroundViewModel(
                entries: { store.entries },
                input: coordinator.lastTranscript ?? PipelineSample.text
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("cleanup")
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 8)

                Text(
                    coordinator.lastTranscript == nil
                        ? "a sample, until you dictate something."
                        : "your last dictation."
                )
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
            }

            HStack(alignment: .top, spacing: 0) {
                stage("heard", lit: true) {
                    flowText(plain(heardText))
                }

                arrow

                stage("cleanup", lit: settings.cleanupEnabled) {
                    Toggle("", isOn: $settings.cleanupEnabled)
                        .labelsHidden()
                        .brandToggleStyle()
                        .controlSize(.mini)
                        .accessibilityLabel("cleanup")

                    if settings.cleanupEnabled {
                        flowText(diffText(heardText, cleanedText))
                    } else {
                        Text("off. only your dictionary still applies.")
                            .foregroundStyle(BrandUI.textSecondary)
                        if cleanedText != heardText {
                            flowText(diffText(heardText, cleanedText))
                        }
                    }
                }

                arrow

                stage("pasted", lit: true) {
                    flowText(plain(finalText))
                }
            }
        }
        .onAppear {
            run.setDeterministicEnabled(settings.cleanupEnabled)
        }
        .onChange(of: settings.cleanupEnabled) { _, enabled in
            run.setDeterministicEnabled(enabled)
        }
        .onChange(of: coordinator.lastTranscript) { _, transcript in
            run.input = transcript ?? PipelineSample.text
            run.recompute()
        }
    }

    // MARK: - pieces

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(BrandUI.gold.opacity(0.55))
            .frame(width: 22)
            .padding(.top, 2)
            .accessibilityHidden(true)
    }

    private func stage<Content: View>(
        _ title: String,
        lit: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit ? BrandUI.gold : BrandUI.textSecondary)
            content()
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(lit ? 1 : 0.6)
    }

    // MARK: - stage text

    private var heardText: String {
        run.results.first?.output ?? run.input
    }

    private var cleanedText: String {
        run.results.first { $0.stage == .deterministic }?.output ?? heardText
    }

    private var finalText: String {
        run.results.last?.output ?? cleanedText
    }

    private func flowText(_ text: AttributedString) -> some View {
        Text(text)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func plain(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.mergeAttributes(Self.ink(BrandUI.textPrimary))
        return out
    }

    /// gold = this stage added it, struck red = this stage took it out.
    private func diffText(_ before: String, _ after: String) -> AttributedString {
        var out = AttributedString()
        for (index, token) in WordDiff.diff(before, after).enumerated() {
            var piece = AttributedString(index == 0 ? token.text : " " + token.text)
            switch token.change {
            case .same:
                piece.mergeAttributes(Self.ink(BrandUI.textPrimary))
            case .added:
                var container = Self.ink(BrandUI.goldPale)
                container[
                    AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self
                ] = BrandUI.gold.opacity(0.18)
                piece.mergeAttributes(container)
            case .removed:
                var container = Self.ink(BrandUI.attention.opacity(0.85))
                container[
                    AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.self
                ] = .single
                piece.mergeAttributes(container)
            }
            out += piece
        }
        return out
    }

    // typed subscripts rather than key paths: the key-path spelling trips
    // a non-Sendable warning under strict concurrency.
    private static func ink(_ color: Color) -> AttributeContainer {
        var container = AttributeContainer()
        container[
            AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self
        ] = color
        return container
    }
}
