import AppKit
import SwiftUI

/// dev only: every lamp ground over every background the lamp meets, in one
/// window, drawn by the real lamp code with the real transitions. the
/// audition is done by eye here; the pick is then lived with through
/// `defaults write <bundle> lampGround <bare|smoke|glass>`.
@MainActor
final class LampLabWindowController: NSWindowController {
    /// `defaults write <bundle> lampLabAtLaunch -bool true` opens the lab on
    /// launch, so a screenshot run needs no clicking.
    static let atLaunchKey = "lampLabAtLaunch"

    init() {
        let hostingController = NSHostingController(
            rootView: LampLabView()
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "lamp lab"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(LampLabView.contentSize)
        window.isReleasedWhenClosed = false
        window.backgroundColor = BrandUI.nsColor(BrandUI.windowBgRGB)
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

struct LampLabView: View {
    static let contentSize = NSSize(width: 920, height: 470)
    static let cellSize = CGSize(width: 272, height: 96)

    enum Stage: String, CaseIterable, Identifiable {
        case ember
        case burn
        case cool
        case text
        case textWithButton

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ember: "ember"
            case .burn: "burn"
            case .cool: "cool"
            case .text: "text"
            case .textWithButton: "text + button"
            }
        }

        var phase: GoldRippleLine.Phase? {
            switch self {
            case .ember: .ember
            case .burn: .burn
            case .cool: .cool
            case .text, .textWithButton: nil
            }
        }
    }

    enum Backdrop: String, CaseIterable, Identifiable {
        case black
        case page
        case desk

        var id: String { rawValue }
    }

    static let sampleText = "nothing was heard, nothing kept"

    @State private var stage: Stage = .burn
    @State private var isLocked = false
    @State private var darkPill = false
    @State private var startedAt = Date()
    @State private var loudness: Float = 0
    @State private var sequenceTask: Task<Void, Never>?

    private let clock = Timer.publish(
        every: 1.0 / 30.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            grid
            Text(
                """
                same drawing code as the live HUD. live with a pick: \
                defaults write \(AppIdentity.bundleID) lampGround smoke
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(
            width: Self.contentSize.width,
            height: Self.contentSize.height
        )
        .onReceive(clock) { _ in
            tick()
        }
        .onChange(of: stage) {
            startedAt = Date()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("stage", selection: $stage) {
                ForEach(Stage.allCases) { stage in
                    Text(stage.label).tag(stage)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(sequenceTask != nil)

            Toggle("locked", isOn: $isLocked)
                .toggleStyle(.checkbox)

            Toggle("dark pill", isOn: $darkPill)
                .toggleStyle(.checkbox)

            Spacer()

            Button(sequenceTask == nil ? "play a dictation" : "stop") {
                if sequenceTask == nil {
                    playSequence()
                } else {
                    sequenceTask?.cancel()
                    sequenceTask = nil
                }
            }
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Color.clear.frame(width: 74, height: 1)
                ForEach(Backdrop.allCases) { backdrop in
                    Text(backdrop.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(LampGround.allCases) { ground in
                GridRow {
                    Text(ground.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .trailing)
                    ForEach(Backdrop.allCases) { backdrop in
                        LampLabCell(
                            ground: ground,
                            backdrop: backdrop,
                            stage: stage,
                            loudness: loudness,
                            startedAt: startedAt,
                            isLocked: isLocked,
                            darkPill: darkPill
                        )
                    }
                }
            }
        }
    }

    /// speech-shaped loudness: bursts with gaps, smoothed like the view
    /// model smooths the mic (fast attack, slow release).
    private func tick() {
        let interval = 1.0 / 30.0
        let t = Date().timeIntervalSinceReferenceDate
        var target: Float = 0
        if stage == .burn {
            let burst = max(0, sin(t * 2.6)) * (0.55 + 0.45 * sin(t * 12.7))
            target = Float(min(1, burst * 1.15))
        }
        let attack = 1 - exp(-interval / 0.040)
        let release = 1 - exp(-interval / 0.200)
        let gain = target > loudness ? attack : release
        loudness += (target - loudness) * Float(gain)
    }

    private func playSequence() {
        sequenceTask?.cancel()
        sequenceTask = Task { @MainActor in
            let script: [(Stage, Double)] = [
                (.ember, 1.0),
                (.burn, 2.6),
                (.cool, 0.7),
                (.burn, 1.4),
                (.text, 1.5),
                (.textWithButton, 1.8),
                (.burn, 1.2),
                (.cool, 0.7),
            ]
            for (next, hold) in script {
                guard !Task.isCancelled else { break }
                stage = next
                try? await Task.sleep(for: .seconds(hold))
            }
            stage = .burn
            sequenceTask = nil
        }
    }
}

private struct LampLabCell: View {
    let ground: LampGround
    let backdrop: LampLabView.Backdrop
    let stage: LampLabView.Stage
    let loudness: Float
    let startedAt: Date
    let isLocked: Bool
    let darkPill: Bool

    @Namespace private var glassNamespace

    private var textLayout: HUDLayout {
        HUDLayoutEngine.layout(
            for: .text(LampLabView.sampleText),
            screenWidth: 1_440
        )
    }

    var body: some View {
        ZStack {
            backdropView
            content
        }
        .frame(
            width: LampLabView.cellSize.width,
            height: LampLabView.cellSize.height
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    /// the glass row morphs the sliver into the pill and materialises the
    /// button; the other rows get today's fade-and-scale.
    private var content: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                if let phase = stage.phase {
                    LampLine(
                        phase: phase,
                        loudness: loudness,
                        startedAt: startedAt,
                        isLocked: isLocked,
                        ground: ground,
                        glassID: ground == .glass ? "hud" : nil,
                        glassNamespace: glassNamespace
                    )
                    .frame(
                        width: HUDLayoutEngine.waveSize.width,
                        height: HUDLayoutEngine.waveSize.height
                    )
                    .transition(fallbackTransition)
                } else {
                    HUDTextPill(
                        message: LampLabView.sampleText,
                        lineCount: textLayout.lineCount,
                        size: textLayout.size,
                        glassTint: darkPill
                            ? BrandUI.black.opacity(0.55)
                            : BrandUI.gold.opacity(0.16)
                    )
                    .glassEffectID(
                        ground == .glass ? "hud" : nil,
                        in: glassNamespace
                    )
                    .transition(fallbackTransition)

                    if stage == .textWithButton {
                        Button("undo") {}
                            .buttonStyle(.glass)
                            .tint(BrandUI.gold)
                            .glassEffectID("undo", in: glassNamespace)
                            .glassEffectTransition(.materialize)
                            .transition(fallbackTransition)
                    }
                }
            }
        }
        .animation(
            .snappy(duration: 0.32, extraBounce: 0.12),
            value: stage
        )
    }

    private var fallbackTransition: AnyTransition {
        ground == .glass
            ? .identity
            : .opacity.combined(with: .scale(scale: 0.94))
    }

    @ViewBuilder
    private var backdropView: some View {
        switch backdrop {
        case .black:
            Color.black
        case .page:
            ZStack {
                Color.white
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.pageLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.black.opacity(0.82))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
            }
        case .desk:
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.33, blue: 0.62),
                        Color(red: 0.66, green: 0.40, blue: 0.52),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.96))
                    .frame(width: 150, height: 70)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(0..<4, id: \.self) { i in
                                Capsule()
                                    .fill(Color(white: 0.72))
                                    .frame(
                                        width: [96, 120, 80, 110][i],
                                        height: 5
                                    )
                            }
                        }
                        .padding(10)
                    }
                    .offset(x: 30, y: 18)
            }
        }
    }

    private static let pageLines = [
        "The lamp sits at the bottom of the screen, where a",
        "document usually ends and the last lines of a message",
        "are still being written. A gold line on white is not a",
        "lamp any more, it is an underline that belongs to no",
        "word. Whatever grounds it has to cost nothing on black.",
    ]
}
