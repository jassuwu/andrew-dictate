import AppKit
import SwiftUI

// compiled into the debug build only: `Capabilities.hasLampLab` decides
// whether it opens, this decides whether release carries it at all.
#if DEBUG
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

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ember: "ember"
            case .burn: "burn"
            case .cool: "cool"
            case .text: "text"
            }
        }

        var phase: GoldRippleLine.Phase? {
            switch self {
            case .ember: .ember
            case .burn: .burn
            case .cool: .cool
            case .text: nil
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
    /// the glass morph only runs inside an animation; the picker and the
    /// sequence go through this so the container has something to blend
    static let morph: Animation = .snappy(duration: 0.36, extraBounce: 0.1)

    @State private var stage: Stage = .burn
    @State private var isLocked = false
    @State private var goldPill = false
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
                the HUD ships "glass, drawn". Liquid Glass draws dimmed in \
                a window that is not key, and the panel never is — the two \
                glass rows only look like this while this window is active
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
            Picker(
                "stage",
                selection: Binding(
                    get: { stage },
                    set: { wanted in
                        withAnimation(LampLabView.morph) {
                            stage = wanted
                        }
                    }
                )
            ) {
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

            Toggle("gold pill", isOn: $goldPill)
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
            ForEach(LampGround.candidates) { ground in
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
                            goldPill: goldPill
                        )
                    }
                }
            }
        }
    }

    /// screenshot runs drive the lab from outside:
    /// `defaults write <bundle> lampLabStage text`, `lampLabLocked -bool true`
    private func followDefaults() {
        let defaults = UserDefaults.standard
        if let mode = defaults.string(forKey: "labDumpNow"),
           let window = NSApp.windows.first(where: { $0.title == "lamp lab" }) {
            defaults.removeObject(forKey: "labDumpNow")
            // the app activates or deactivates itself: another process
            // cannot make it frontmost on modern macOS
            if mode == "active" {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                NSApp.deactivate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                HUDHierarchyDump.write(
                    window: window,
                    to: "/tmp/lab-\(mode).txt"
                )
            }
        }
        if let raw = defaults.string(forKey: "lampLabStage"),
           let wanted = Stage(rawValue: raw),
           wanted != stage,
           sequenceTask == nil {
            withAnimation(LampLabView.morph) {
                stage = wanted
            }
        }
        let locked = defaults.bool(forKey: "lampLabLocked")
        if locked != isLocked {
            isLocked = locked
        }
    }

    /// speech-shaped loudness: bursts with gaps, smoothed like the view
    /// model smooths the mic (fast attack, slow release).
    private func tick() {
        followDefaults()
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
                (.text, 1.8),
                (.burn, 1.2),
                (.cool, 0.7),
            ]
            for (next, hold) in script {
                guard !Task.isCancelled else { break }
                withAnimation(LampLabView.morph) {
                    stage = next
                }
                try? await Task.sleep(for: .seconds(hold))
            }
            withAnimation(LampLabView.morph) {
                stage = .burn
            }
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
    let goldPill: Bool

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

    /// the glass rows morph the sliver or ribbon into the pill; the other
    /// rows get today's fade-and-scale.
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
                        glassID: ground.isGlass ? "hud" : nil,
                        glassNamespace: glassNamespace
                    )
                    .frame(
                        width: HUDLayoutEngine.waveSize.width,
                        height: HUDLayoutEngine.waveSize.height
                    )
                    .modifier(RowTransition(ground: ground))
                } else {
                    HUDTextPill(
                        message: LampLabView.sampleText,
                        lineCount: textLayout.lineCount,
                        size: textLayout.size,
                        glassTint: goldPill
                            ? BrandUI.gold.opacity(0.16)
                            : HUDTextPill.darkTint
                    )
                    .glassEffectID(
                        ground.isGlass ? "hud" : nil,
                        in: glassNamespace
                    )
                    .modifier(RowTransition(ground: ground))
                }
            }
        }
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

/// glass rows leave the transition to the container, which morphs one glass
/// shape into the next; the plain rows keep today's fade-and-scale.
private struct RowTransition: ViewModifier {
    let ground: LampGround

    func body(content: Content) -> some View {
        if ground.isGlass {
            content
        } else {
            content.transition(
                .opacity.combined(with: .scale(scale: 0.94))
            )
        }
    }
}
#endif
