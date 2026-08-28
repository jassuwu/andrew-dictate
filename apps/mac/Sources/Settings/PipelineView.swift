import SwiftUI

/// the cleanup pipeline as a pipe: five sections of one tube, the text
/// riding through it, and the one switch sitting on the one section that
/// has one. your last dictation flows through live; before any, a sample.
struct PipelineView: View {
    @ObservedObject private var settings: AppSettings
    @StateObject private var run: PipelinePlaygroundViewModel
    private let lastTranscript: String?
    private let unavailableReason: String?

    init(coordinator: DictationCoordinator, settings: AppSettings) {
        _settings = ObservedObject(wrappedValue: settings)
        lastTranscript = coordinator.lastTranscript
        unavailableReason = coordinator.cleanupUnavailableExplanation
        let store = coordinator.dictionaryStore
        _run = StateObject(
            wrappedValue: PipelinePlaygroundViewModel(
                entries: { store.entries },
                input: coordinator.lastTranscript ?? PipelineSample.text
            )
        )
    }

    private var polishWanted: Bool {
        settings.cleanupMode != .off
    }

    private var polishLit: Bool {
        polishWanted && unavailableReason == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("cleanup")
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 8)

                Text(
                    lastTranscript == nil
                        ? "a sample, until you dictate something."
                        : "your last dictation, live."
                )
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
            }

            PipeTrack(lit: [true, true, true, polishLit, true])
                .frame(height: 26)

            HStack(alignment: .top, spacing: 0) {
                column(title: "you speak", lit: true) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(BrandUI.gold)
                        .font(.system(size: 13))
                    Text("hold fn, talk, let go.")
                        .foregroundStyle(BrandUI.textSecondary)
                }

                column(title: "speech model", lit: true) {
                    flowText(plain(heardText))
                }

                column(title: "cleanup", lit: true) {
                    flowText(diffText(heardText, cleanedText))
                }

                column(title: "ai polish", lit: polishLit) {
                    Picker("", selection: $settings.cleanupMode) {
                        ForEach(CleanupMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .accessibilityLabel("ai polish")
                    .padding(.bottom, 2)

                    polishBody
                }

                column(title: "lands at your cursor", lit: true) {
                    flowText(plain(finalText))
                }
            }
        }
        .onAppear {
            run.setPolishEnabled(polishWanted)
        }
        .onChange(of: settings.cleanupMode) { _, _ in
            run.setPolishEnabled(polishWanted)
        }
        .onChange(of: lastTranscript) { _, transcript in
            run.input = transcript ?? PipelineSample.text
            run.recompute()
        }
    }

    // MARK: - stage text

    private var heardText: String {
        run.results.first?.output ?? run.input
    }

    private var cleanedText: String {
        run.results.first { $0.stage == .deterministic }?.output ?? heardText
    }

    private var polish: PipelineStageResult? {
        run.results.first { $0.stage == .polish }
    }

    private var finalText: String {
        run.results.last?.output ?? cleanedText
    }

    @ViewBuilder
    private var polishBody: some View {
        if !polishWanted {
            Text("off. the words stay exactly yours.")
                .foregroundStyle(BrandUI.textSecondary)
        } else if let unavailableReason {
            Text(unavailableReason)
                .foregroundStyle(BrandUI.textSecondary)
        } else if run.isPolishing {
            Text("polishing…")
                .foregroundStyle(BrandUI.textSecondary)
        } else if let polish, let reason = polish.unavailableReason {
            Text(reason)
                .foregroundStyle(BrandUI.textSecondary)
        } else if let polish, !polish.changedAnything {
            Text("nothing to add this time.")
                .foregroundStyle(BrandUI.textSecondary)
        } else {
            flowText(diffText(cleanedText, finalText))
        }
    }

    private func column<Content: View>(
        title: String,
        lit: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit ? BrandUI.gold : BrandUI.textSecondary)
                .lineLimit(1)
            content()
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .opacity(lit ? 1 : 0.6)
    }

    private func flowText(_ text: AttributedString) -> some View {
        Text(text)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .help(String(text.characters))
    }

    private func plain(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        out.mergeAttributes(Self.ink(BrandUI.textPrimary))
        return out
    }

    /// gold = this section added it, struck red = this section took it out.
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

/// one tube, `lit.count` sections, a coupling ring at every joint. an unlit
/// section is hollow: the text passes through it untouched.
struct PipeTrack: View {
    let lit: [Bool]

    var body: some View {
        Canvas { context, size in
            let thickness: CGFloat = 12
            let y = (size.height - thickness) / 2
            let count = max(lit.count, 1)
            let sectionWidth = size.width / CGFloat(count)
            let tube = Path(
                roundedRect: CGRect(
                    x: 0, y: y, width: size.width, height: thickness
                ),
                cornerRadius: thickness / 2
            )

            context.fill(tube, with: .color(BrandUI.black.opacity(0.55)))

            for (index, isLit) in lit.enumerated() where isLit {
                var clipped = context
                clipped.clip(to: tube)
                let x = CGFloat(index) * sectionWidth
                let rect = CGRect(
                    x: x, y: y, width: sectionWidth, height: thickness
                )
                clipped.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: [BrandUI.gold, BrandUI.goldDeep]),
                        startPoint: CGPoint(x: x, y: y),
                        endPoint: CGPoint(x: x, y: y + thickness)
                    )
                )
            }

            context.stroke(tube, with: .color(BrandUI.hairline), lineWidth: 1)

            for index in 1..<count {
                let x = CGFloat(index) * sectionWidth
                let radius = thickness / 2 + 3
                let ring = Path(
                    ellipseIn: CGRect(
                        x: x - radius,
                        y: y + thickness / 2 - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                context.fill(ring, with: .color(BrandUI.windowBg))
                context.stroke(
                    ring,
                    with: .color(BrandUI.gold.opacity(0.7)),
                    lineWidth: 1.5
                )
            }
        }
        .accessibilityHidden(true)
    }
}
