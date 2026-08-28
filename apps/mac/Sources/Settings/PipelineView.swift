import AppKit
import SwiftUI

/// the cleanup pipeline as a pipe: five sections of one tube, a coupling
/// ring at every joint, the one switch on each section that has one.
///
/// two sizes of the same thing (ADR 0038): `.strip` is the control that
/// lives in the dictation pane — tube, names, switches — and `.stage` is
/// the pop-out where the text actually rides through: type anything, or
/// let your last dictation flow, and watch each section hand it on.
struct PipelineView: View {
    enum Mode {
        case strip
        case stage
    }

    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var run: PipelinePlaygroundViewModel
    private let mode: Mode

    /// how many sections the text has reached, for the conveyor reveal.
    @State private var revealed = 5
    @State private var revealTask: Task<Void, Never>?

    init(
        coordinator: DictationCoordinator,
        settings: AppSettings,
        mode: Mode
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: settings)
        self.mode = mode
        let store = coordinator.dictionaryStore
        _run = StateObject(
            wrappedValue: PipelinePlaygroundViewModel(
                entries: { store.entries },
                input: coordinator.lastTranscript ?? PipelineSample.text
            )
        )
    }

    private var unavailableReason: String? {
        coordinator.cleanupUnavailableExplanation
    }

    private var polishWanted: Bool {
        settings.cleanupMode != .off
    }

    private var polishLit: Bool {
        polishWanted && unavailableReason == nil
    }

    private var sectionsLit: [Bool] {
        [true, true, settings.cleanupEnabled, polishLit, true]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: mode == .stage ? 18 : 12) {
            header

            if mode == .stage {
                inputField
            }

            PipeTrack(
                lit: sectionsLit.enumerated().map { $1 && $0 < revealed }
            )
            .frame(height: mode == .stage ? 30 : 26)
            .contentShape(Rectangle())
            .onTapGesture {
                if mode == .strip {
                    coordinator.openPipeline()
                }
            }

            HStack(alignment: .top, spacing: 0) {
                column(0, title: "you speak", lit: true) {
                    if mode == .stage {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(BrandUI.gold)
                            .font(.system(size: 14))
                        Text("hold fn, talk, let go.")
                            .foregroundStyle(BrandUI.textSecondary)
                    }
                }

                column(1, title: "speech model", lit: true) {
                    if mode == .stage {
                        flowText(plain(heardText))
                    }
                }

                column(2, title: "cleanup", lit: settings.cleanupEnabled) {
                    Toggle("", isOn: $settings.cleanupEnabled)
                        .labelsHidden()
                        .brandToggleStyle()
                        .controlSize(.mini)
                        .accessibilityLabel("cleanup")

                    if mode == .stage {
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
                }

                column(3, title: "ai polish", lit: polishLit) {
                    Picker("", selection: $settings.cleanupMode) {
                        ForEach(CleanupMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .accessibilityLabel("ai polish")

                    if mode == .stage {
                        polishBody
                    } else if polishWanted, let unavailableReason {
                        // the one caption the strip keeps: a switch that
                        // does nothing must say why, right there.
                        Text(unavailableReason)
                            .font(.system(size: 10))
                            .foregroundStyle(BrandUI.textSecondary)
                            .lineLimit(3)
                    }
                }

                column(4, title: "lands at your cursor", lit: true) {
                    if mode == .stage {
                        flowText(plain(finalText))
                    }
                }
            }

            if mode == .stage {
                Text("gold — that section added it · struck red — it took it out")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }
        }
        .onAppear {
            run.setDeterministicEnabled(settings.cleanupEnabled)
            run.setPolishEnabled(polishWanted)
            if mode == .stage {
                replay()
            }
        }
        .onChange(of: settings.cleanupMode) { _, _ in
            run.setPolishEnabled(polishWanted)
        }
        .onChange(of: settings.cleanupEnabled) { _, enabled in
            run.setDeterministicEnabled(enabled)
        }
        .onChange(of: coordinator.lastTranscript) { _, transcript in
            run.input = transcript ?? PipelineSample.text
            run.recompute()
            replay()
        }
    }

    // MARK: - pieces

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Text(mode == .stage ? "what happens to your words" : "cleanup")
                .font(
                    mode == .stage
                        ? .system(size: 17, weight: .semibold)
                        : BrandUI.bodyFont.weight(.medium)
                )

            Spacer(minLength: 8)

            if mode == .stage {
                Text(
                    coordinator.lastTranscript == nil
                        ? "a sample, until you dictate something."
                        : "your last dictation. type to try your own."
                )
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
            } else {
                Button("watch it flow…") {
                    coordinator.openPipeline()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(BrandUI.gold)
            }
        }
    }

    /// the stage's superpower: it doesn't have to be something you said.
    private var inputField: some View {
        TextField(
            "type or paste anything — it runs through live",
            text: $run.input,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(BrandUI.bodyFont)
        .lineLimit(2...4)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandUI.cardBg)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BrandUI.hairline, lineWidth: 1)
        }
        .onChange(of: run.input) { _, _ in
            run.recompute()
            replay()
        }
    }

    /// the conveyor: sections light and their text appears left to right,
    /// so a change reads as the words travelling rather than a repaint.
    private func replay() {
        revealTask?.cancel()
        revealed = 1
        revealTask = Task { @MainActor in
            for step in 2...5 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else {
                    return
                }
                withAnimation(.easeOut(duration: 0.22)) {
                    revealed = step
                }
            }
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
        _ index: Int,
        title: String,
        lit: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit ? BrandUI.gold : BrandUI.textSecondary)
                .lineLimit(1)
            content()
        }
        .font(.system(size: mode == .stage ? 12 : 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .opacity(lit ? 1 : 0.6)
        .opacity(index < revealed ? 1 : 0.12)
    }

    private func flowText(_ text: AttributedString) -> some View {
        Text(text)
            .lineLimit(mode == .stage ? 10 : 5)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
        .animation(.easeOut(duration: 0.22), value: lit)
        .accessibilityHidden(true)
    }
}

/// the pop-out. same chrome as the stamp (0032): no visible title bar, the
/// content on the window itself.
@MainActor
final class PipelineWindowController: NSWindowController {
    init(coordinator: DictationCoordinator) {
        let rootView = PipelineView(
            coordinator: coordinator,
            settings: coordinator.settings,
            mode: .stage
        )
        .padding(.top, 34)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: 960, alignment: .top)
        .background(BrandUI.windowBg)
        .foregroundStyle(BrandUI.textPrimary)
        .brandTinted()
        .preferredColorScheme(.dark)

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "what happens to your words"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = BrandUI.nsColor(BrandUI.windowBgRGB)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 960, height: 440))
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
