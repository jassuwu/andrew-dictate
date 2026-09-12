import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import SwiftUI

@MainActor
private final class OnboardingWindowResizer {
    weak var window: NSWindow?

    func resize(to contentHeight: CGFloat, animated: Bool) {
        // Window mutations are deferred past the SwiftUI graph update that
        // requested them, matching the HUD/AttributeGraph safety rule.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else {
                return
            }

            let currentFrame = window.frame
            let targetFrameSize = window.frameRect(
                forContentRect: NSRect(
                    origin: .zero,
                    size: NSSize(width: 460, height: contentHeight)
                )
            ).size
            guard abs(currentFrame.height - targetFrameSize.height) > 0.5
            else {
                return
            }

            let targetFrame = NSRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - targetFrameSize.height,
                width: targetFrameSize.width,
                height: targetFrameSize.height
            )
            window.setFrame(
                targetFrame,
                display: true,
                animate: animated
                    && !NSWorkspace.shared
                        .accessibilityDisplayShouldReduceMotion
            )
        }
    }
}

@MainActor
final class OnboardingWindowController:
    NSWindowController,
    NSWindowDelegate
{
    /// which jobs this window was built for; a different ask needs a
    /// different window.
    let scope: OnboardingScope

    private weak var coordinator: DictationCoordinator?

    /// `scope` and the two meeting closures are the whole seam: the coordinator
    /// says which errand this window is for and hands it the real probe and the
    /// real download when they exist. Defaults keep every existing call site —
    /// and the stubs — working unchanged.
    init(
        coordinator: DictationCoordinator,
        scope: OnboardingScope = .everything,
        proveSystemAudio: @escaping OnboardingMeetingSetup.SystemAudioProof =
            OnboardingMeetingSetup.stubbedSystemAudioProof,
        prepareMeetingModel:
            @escaping OnboardingMeetingSetup.MeetingModelPreparation =
                OnboardingMeetingSetup.stubbedMeetingModelPreparation
    ) {
        self.coordinator = coordinator
        self.scope = scope

        let resizer = OnboardingWindowResizer()
        let rootView = OnboardingView(
            coordinator: coordinator,
            scope: scope,
            meetingSetup: OnboardingMeetingSetup(
                proveSystemAudio: proveSystemAudio,
                prepareMeetingModel: prepareMeetingModel
            ),
            windowResizer: resizer
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        resizer.window = window
        window.title = "Andrew Dictate"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 430))
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()

        super.init(window: window)
        window.delegate = self
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

    func windowWillClose(_ notification: Notification) {
        coordinator?.onboardingWindowDidClose(self)
    }
}

@MainActor
private final class OnboardingPermissionModel: ObservableObject {
    @Published private(set) var microphoneStatus: AVAuthorizationStatus
    @Published private(set) var accessibilityGranted: Bool

    private var accessibilityPromptTriggered = false

    init() {
        microphoneStatus =
            AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func refresh() {
        microphoneStatus =
            AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestMicrophoneAccess(
        requestAccess: @escaping @MainActor () async -> Bool
    ) {
        Task { @MainActor [weak self] in
            _ = await requestAccess()
            self?.microphoneStatus =
                AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func requestAccessibilityPrompt() {
        guard !accessibilityPromptTriggered else {
            return
        }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:
                true
        ] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        accessibilityPromptTriggered = true
    }

    func openMicrophoneSettings() {
        openPrivacySettings(
            "com.apple.preference.security?Privacy_Microphone"
        )
    }

    func openAccessibilitySettings() {
        openPrivacySettings(
            "com.apple.preference.security?Privacy_Accessibility"
        )
    }

    private func openPrivacySettings(_ path: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:" + path
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// What the key test has to say, in one value.
///
/// `pickerShown` is sticky on purpose: once setup has offered another key,
/// withdrawing the offer the moment it is taken would read as a glitch. One
/// state change on the first bump, and no staged "let go" beat — detection-only
/// mode returns early on release, so a second beat would be a timer pretending
/// to watch the user.
private struct KeyTest: Equatable {
    var fired = false
    var patienceSpent = false
    var pickerShown = false
    /// changing this re-arms the wait, which is how a freshly picked key gets
    /// its own six seconds.
    var armedAt = Date()

    mutating func markFired() {
        fired = true
    }

    mutating func spendPatience() {
        patienceSpent = true
        pickerShown = true
    }

    mutating func rearm() {
        fired = false
        patienceSpent = false
        armedAt = Date()
    }

    func caption(for binding: HotkeyBinding) -> String {
        if fired {
            return "got it. that key works on this keyboard."
        }
        guard patienceSpent else {
            return "press and hold it."
        }
        // the fn sentence is only true about fn: someone who rebound in
        // settings and reran setup would be told a lie.
        return binding == .fn
            ? "nothing yet — fn only exists on apple keyboards. try another:"
            : "nothing yet. try another key:"
    }
}

struct OnboardingView: View {
    // Every screen is the same size. The window used to grow from 430 to 648
    // when setup began, moving itself under the pointer at the exact moment
    // the user was reaching for something.
    private static let windowWidth: CGFloat = 460
    private static let windowHeight: CGFloat = 430

    /// How long setup waits for the key before offering another one. A
    /// provisional number, like the dead-tap window: long enough that nobody
    /// is accused of not trying, short enough to still be on this screen.
    private static let keyTestPatience: TimeInterval = 6

    @Environment(\.controlActiveState) private var controlActiveState

    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var permissions: OnboardingPermissionModel
    @StateObject private var meetingSetup: OnboardingMeetingSetup
    @State private var onboarding: OnboardingState
    @State private var flow = OnboardingFlow()
    @State private var keyTest = KeyTest()

    private let windowResizer: OnboardingWindowResizer

    fileprivate init(
        coordinator: DictationCoordinator,
        scope: OnboardingScope,
        meetingSetup: OnboardingMeetingSetup,
        windowResizer: OnboardingWindowResizer
    ) {
        let permissions = OnboardingPermissionModel()
        var onboarding = OnboardingState(scope: scope)
        onboarding.updateMicrophoneStatus(
            Self.microphoneRowStatus(for: permissions.microphoneStatus)
        )
        onboarding.updateAccessibility(
            granted: permissions.accessibilityGranted
        )
        onboarding.updateModelStatus(
            Self.modelRowStatus(for: coordinator.enginePreparationState)
        )

        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: coordinator.settings)
        _permissions = StateObject(wrappedValue: permissions)
        _meetingSetup = StateObject(wrappedValue: meetingSetup)
        _onboarding = State(initialValue: onboarding)
        self.windowResizer = windowResizer
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            stepBody
            Spacer(minLength: 10)
            navigation
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .brandGlassWindow()
        .foregroundStyle(BrandUI.textPrimary)
        .font(BrandUI.bodyFont)
        .brandTinted()
        .controlSize(.small)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: flow.step)
        .onAppear {
            permissions.refresh()
            synchronizeOnboarding()
            windowResizer.resize(to: Self.windowHeight, animated: false)
        }
        .onChange(of: permissions.microphoneStatus) { _, _ in
            synchronizePermissions()
        }
        .onChange(of: permissions.accessibilityGranted) { _, _ in
            synchronizePermissions()
        }
        .onChange(of: coordinator.enginePreparationState) { _, _ in
            synchronizeEngine()
        }
        // the press itself, published on every bump of the bound key. the
        // window is key while setup is on screen, so the local monitor
        // delivers it without accessibility being granted yet.
        .onChange(of: coordinator.hotkeyDetection) { _, detection in
            guard detection != nil else {
                return
            }
            keyTest.markFired()
        }
        .onChange(of: meetingSetup.systemAudioStatus) { _, _ in
            synchronizeMeetings()
        }
        .onChange(of: meetingSetup.modelStatus) { _, _ in
            synchronizeMeetings()
        }
        // Coming back from privacy settings is the one moment re-proving is
        // worth a sound: the switch you just flipped is the only thing that
        // could have changed the answer.
        .onChange(of: controlActiveState) { _, state in
            if state == .key {
                meetingSetup.proveSystemAudioAgain()
            }
        }
        // The permission rows are read from the system every second, so a
        // grant made in System Settings shows up here without the user having
        // to come back and prod anything.
        .task {
            permissions.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                permissions.refresh()
            }
        }
    }

    // MARK: - the screens

    private var stepBody: some View {
        VStack(spacing: 10) {
            if flow.step == .hello {
                Image("Badge")
                    .resizable()
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)
                    .padding(.bottom, 2)
            }

            Text(flow.step.title(for: onboarding.jobs))
                .font(.system(size: 22, weight: .semibold))

            if flow.step == .hello, onboarding.scope == .everything {
                Text("escape the keyboard.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(BrandUI.gold)
            }

            Text(
                flow.step.reason(
                    for: onboarding.jobs,
                    key: settings.dictationHotkey.displayName
                )
            )
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)

            switch flow.step {
            case .hello:
                jobRows.padding(.top, 14)
            case .model:
                VStack(spacing: 18) {
                    modelProgress
                    keyTestBlock
                }
                .padding(.top, 10)
            case .permissions:
                permissionRows.padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Two jobs, both priced; dictation on, meetings offered. Ticking or
    /// unticking one adds or takes its rows and its download — the fork is
    /// here and nowhere else (ADR 0040).
    /// In `meetingsOnly` there is nothing to choose: pressing `record a
    /// meeting` was the choice.
    @ViewBuilder
    private var jobRows: some View {
        if onboarding.scope == .everything {
            VStack(spacing: 0) {
                jobRow(
                    "dictation",
                    size: OnboardingJobs.dictationDownload,
                    isOn: onboarding.dictationSelected
                ) {
                    onboarding.setDictationSelected(
                        !onboarding.dictationSelected
                    )
                }

                Divider().overlay(BrandUI.hairline).padding(.vertical, 10)

                jobRow(
                    "meeting recording",
                    size: OnboardingJobs.meetingsDownload,
                    isOn: onboarding.meetingsSelected
                ) {
                    onboarding.setMeetingsSelected(
                        !onboarding.meetingsSelected
                    )
                }
            }
            .frame(maxWidth: 330)
        }
    }

    private func jobRow(
        _ name: String,
        size: String,
        isOn: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? BrandUI.gold : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(
                                isOn
                                    ? BrandUI.gold
                                    : BrandUI.textPrimary.opacity(0.28),
                                lineWidth: 1
                            )
                    }
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(BrandUI.windowBg)
                            .opacity(isOn ? 1 : 0)
                    }
                    .frame(width: 16, height: 16)

                Text(name)
                    .foregroundStyle(
                        isOn ? BrandUI.textPrimary : BrandUI.textSecondary
                    )
                Text("·")
                    .foregroundStyle(BrandUI.textSecondary)
                Text(size)
                    .font(BrandUI.valueFont)
                    .foregroundStyle(BrandUI.textSecondary)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// One block per ticked job, labelled only when there are two of them —
    /// a lone download does not need to say which job it is for.
    @ViewBuilder
    private var modelProgress: some View {
        let bothJobs =
            onboarding.dictationSelected && onboarding.meetingsSelected

        VStack(spacing: 14) {
            if onboarding.dictationSelected {
                VStack(spacing: 6) {
                    if bothJobs {
                        BrandSectionHeader("dictation")
                    }
                    dictationModelProgress
                }
            }

            if onboarding.meetingsSelected {
                VStack(spacing: 6) {
                    if bothJobs {
                        BrandSectionHeader("meetings")
                    }
                    meetingModelProgress
                }
            }
        }
    }

    /// The download does not gate anything. It starts when the user says go and
    /// keeps running while they carry on — blocking the flow on ~460 MB was the
    /// thing that made setup feel long.
    @ViewBuilder
    private var dictationModelProgress: some View {
        switch coordinator.enginePreparationState {
        case let .downloading(progress):
            VStack(spacing: 7) {
                ProgressView(value: bounded(progress))
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("about \(coordinator.settings.engineVersion.approximateSize.dropFirst()). carry on — this keeps going.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }
        case .warmingUp:
            Text("warming up…")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        case .ready:
            // The models live in FluidAudio's shared folder, not this app's, so
            // another app on this mac may already have fetched them — or a
            // previous install did. Saying nothing here would let the user
            // assume a download happened and quietly took their bandwidth.
            Text("found it already on this mac. nothing to download.")
                .font(.caption)
                .foregroundStyle(BrandUI.gold)
        case .failed:
            VStack(spacing: 7) {
                Text("that download didn't finish.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.attention)
                Button("try again") { coordinator.retryEnginePrewarm() }
                    .font(.caption)
            }
        case .notStarted:
            Text("starting…")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        }
    }

    /// The same idiom as the dictation model, one job over: it starts on the
    /// click, it says what it costs, and a failure offers the retry rather
    /// than leaving a dead row.
    @ViewBuilder
    private var meetingModelProgress: some View {
        switch meetingSetup.modelStatus {
        case .pending:
            Text("starts when you click.")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        case .inProgress:
            VStack(spacing: 7) {
                ProgressView(value: bounded(meetingSetup.modelProgress))
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("about \(coordinator.settings.meetingModel.approximateSize.dropFirst()). carry on — this keeps going.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }
        case .ready:
            Text("got it. it hears every language and writes english.")
                .font(.caption)
                .foregroundStyle(BrandUI.gold)
        case .actionRequired:
            VStack(spacing: 7) {
                Text("that download didn't finish.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.attention)
                Button("try again") { meetingSetup.retryModel() }
                    .font(.caption)
            }
        }
    }

    /// Proof, not configuration. The key is the one part of dictation setup
    /// cannot verify for you — fn does not exist on a Keychron, and the app
    /// would otherwise say nothing about it ever again. So the press happens
    /// here, while there is still a screen to answer on, and the picker
    /// appears only after the shipped default has visibly failed to fire.
    ///
    /// A meetings-only setup has no key to prove, and before consent there is
    /// nothing to prove it for.
    @ViewBuilder
    private var keyTestBlock: some View {
        if onboarding.consented, onboarding.dictationSelected {
            VStack(spacing: 6) {
                BrandSectionHeader("your key")

                HStack(alignment: .top, spacing: 9) {
                    if keyTest.pickerShown {
                        keyPicker
                    } else {
                        KeyChip(
                            settings.dictationHotkey.displayName,
                            isActive: keyTest.fired
                        )
                    }

                    Text(
                        keyTest.caption(for: settings.dictationHotkey)
                    )
                    .font(.caption)
                    .foregroundStyle(
                        keyTest.fired ? BrandUI.gold : BrandUI.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                // the tallest state's height from the first render: the
                // picker must not push the card around under the pointer.
                .frame(height: 38, alignment: .top)
            }
            .frame(maxWidth: 330)
            .task(id: keyTest.armedAt) {
                do {
                    try await Task.sleep(for: .seconds(Self.keyTestPatience))
                } catch {
                    return
                }
                guard !keyTest.fired else {
                    return
                }
                keyTest.spendPatience()
            }
        }
    }

    /// The same menu settings owns (one key picker in the app, rendered
    /// twice), so a pick here is the real rebind and not a setup-only draft.
    private var keyPicker: some View {
        Menu {
            ForEach(HotkeyBinding.supported) { binding in
                Button(binding.displayName) {
                    rebindForKeyTest(to: binding)
                }
            }
        } label: {
            HStack(spacing: 4) {
                KeyChip(
                    settings.dictationHotkey.displayName,
                    isActive: keyFired
                )
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(BrandUI.textSecondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("dictation key")
    }

    private func rebindForKeyTest(to binding: HotkeyBinding) {
        guard coordinator.rebindHotkey(to: binding) else {
            return
        }
        // the new key gets its own six seconds; the picker stays, because
        // taking the offer back the moment it was used would read as a bug.
        keyTest.rearm()
    }

    /// One checklist, filtered by job: nothing here belongs to a job the user
    /// unticked, because a row you cannot need is a row you have to wonder
    /// about.
    private var permissionRows: some View {
        VStack(spacing: 0) {
            permissionRow(
                "microphone",
                status: onboarding.microphoneStatus,
                note: "switch the microphone on for andrew dictate.",
                allow: {
                    permissions.requestMicrophoneAccess {
                        await coordinator.requestMicrophoneAccess()
                    }
                },
                openSettings: permissions.openMicrophoneSettings
            )

            if onboarding.dictationSelected {
                rowDivider

                permissionRow(
                    "accessibility",
                    status: onboarding.accessibilityStatus,
                    note: "find andrew dictate in the list and switch it on.",
                    allow: permissions.requestAccessibilityPrompt,
                    openSettings: permissions.openAccessibilitySettings
                )
            }

            if onboarding.meetingsSelected {
                rowDivider
                systemAudioRow
                rowDivider
                meetingModelRow
            }
        }
        .frame(maxWidth: 330)
    }

    private var rowDivider: some View {
        Divider().overlay(BrandUI.hairline).padding(.vertical, 10)
    }

    /// Not a question — a demonstration. The app plays its own start sound
    /// into its own tap, which is both the proof and the thing that makes
    /// macOS ask (ADR 0021, ADR 0040). So this row narrates instead of
    /// offering an "allow" button: there is nothing here for you to click
    /// unless it fails.
    private var systemAudioRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("system audio")
                .foregroundStyle(BrandUI.textPrimary)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                switch meetingSetup.systemAudioStatus {
                case .pending:
                    rowNote("proved when you click, by playing a sound")
                case .inProgress:
                    rowNote("playing a sound to prove it can hear…")
                case .ready:
                    rowVerdict("heard it")
                case .actionRequired:
                    rowNote(
                        "couldn't hear — allow system audio recording in "
                            + "privacy settings",
                        colour: BrandUI.attention
                    )
                    Button("open privacy settings") {
                        meetingSetup.openSystemAudioSettings()
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    private var meetingModelRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("meeting model")
                .foregroundStyle(BrandUI.textPrimary)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                switch meetingSetup.modelStatus {
                case .pending:
                    rowNote("downloads when you click")
                case .inProgress:
                    ProgressView(value: bounded(meetingSetup.modelProgress))
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                    rowNote(OnboardingJobs.meetingsDownload)
                case .ready:
                    rowVerdict("downloaded")
                case .actionRequired:
                    rowNote(
                        "that download didn't finish.",
                        colour: BrandUI.attention
                    )
                    Button("try again") { meetingSetup.retryModel() }
                        .font(.caption)
                }
            }
            .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    private func rowNote(
        _ text: String,
        colour: Color = BrandUI.textSecondary
    ) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(colour)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowVerdict(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(BrandUI.gold)
    }

    /// Says what is true right now, in a word. The previous version showed
    /// three rows reading "pending" before consent had even been given, which
    /// reads as broken rather than waiting.
    /// `note` is the sentence the pane cannot say for us: privacy settings
    /// opens on a list, and which row to touch is the one thing the user is
    /// left guessing. Only shown alongside "open settings" — a granted
    /// permission has nothing to instruct.
    private func permissionRow(
        _ name: String,
        status: OnboardingRowStatus,
        note: String? = nil,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .foregroundStyle(BrandUI.textPrimary)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                switch status {
                case .ready:
                    rowVerdict("granted")
                case .actionRequired:
                    Button("open settings", action: openSettings)
                        .font(.caption)
                    if let note {
                        // default colour: a permission you have not given
                        // yet is not a failure, and attention is for things
                        // that went wrong.
                        rowNote(note)
                    }
                case .inProgress:
                    rowNote("asking…")
                case .pending:
                    Button("allow", action: allow)
                        .font(.caption)
                }
            }
            .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    // MARK: - exactly one thing to do

    // MARK: - one row, at the bottom, with one way forward

    /// The first version of this screen had a `>` chevron at the top *and* a
    /// "get started" button at the bottom — two controls doing one job, which
    /// is the ambiguity the whole redesign is supposed to be removing. They are
    /// the same control now: the call to action **is** the forward button.
    ///
    /// There is no skip. Someone who launched the app launched it in order to
    /// set it up, and macOS already provides the exit — the window is
    /// `.closable`, and closing it leaves setup to return next launch rather
    /// than silencing it (SPEC §5).
    private var navigation: some View {
        ZStack {
            // Centred independently of the buttons, which are different widths
            // and would otherwise push the dots off-centre.
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases) { step in
                    Button {
                        flow.jump(to: step)
                    } label: {
                        Circle()
                            .fill(
                                step == flow.step
                                    ? BrandUI.gold
                                    : BrandUI.textPrimary.opacity(0.22)
                            )
                            .frame(width: 6, height: 6)
                            .contentShape(Rectangle())
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.title(for: onboarding.jobs))
                }
            }

            HStack {
                Button {
                    flow.goBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("back")
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(BrandUI.textSecondary)
                .opacity(flow.canGoBack ? 1 : 0)
                .disabled(!flow.canGoBack)

                Spacer()

                Button(action: performPrimaryAction) {
                    HStack(spacing: 5) {
                        Text(flow.step.actionTitle(for: onboarding.jobs))
                        Image(
                            systemName: flow.canGoForward
                                ? "chevron.right"
                                : "checkmark"
                        )
                        .font(.system(size: 10, weight: .semibold))
                    }
                }
                // the one prominent control on the surface gets the glass
                // (ADR 0036); everything else stays quiet.
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                // No job, no setup: there is nothing this click could start.
                .disabled(
                    flow.step == .hello && !onboarding.jobs.anySelected
                )
            }
        }
    }

    private func performPrimaryAction() {
        switch flow.step {
        case .hello:
            guard onboarding.jobs.anySelected else {
                return
            }
            onboarding.consentToSetup()
            synchronizePermissions()
            // Kick the downloads off here so they run underneath the rest of
            // setup rather than in front of it. Each job starts its own, and
            // only the ticked ones — "nothing downloads before the click"
            // means nothing you didn't ask for downloads after it either.
            if onboarding.dictationSelected {
                // macOS explains this ask better than any line on this card
                // can, and answering it either way is what registers the app
                // in privacy › accessibility — so "open settings" arrives at
                // a list andrew dictate is actually in. Inside the dictation
                // gate: a meetings-only setup is never asked (SPEC §5).
                permissions.requestAccessibilityPrompt()
                coordinator.beginOnboardingEnginePreparation()
            }
            if onboarding.meetingsSelected {
                meetingSetup.begin()
            }
            flow.advance()

        case .model:
            flow.advance()

        case .permissions:
            coordinator.finishOnboarding(
                dictationWanted: onboarding.scope == .everything
                    ? onboarding.dictationSelected
                    : nil
            )
        }
    }

    // MARK: - keeping the state in step with the system

    private func synchronizeOnboarding() {
        synchronizePermissions()
        synchronizeEngine()
        synchronizeMeetings()
    }

    private func synchronizeMeetings() {
        onboarding.updateSystemAudioStatus(meetingSetup.systemAudioStatus)
        onboarding.updateMeetingModelStatus(meetingSetup.modelStatus)
    }

    private func synchronizePermissions() {
        onboarding.updateMicrophoneStatus(
            Self.microphoneRowStatus(for: permissions.microphoneStatus)
        )
        onboarding.updateAccessibility(
            granted: permissions.accessibilityGranted
        )
    }

    private func synchronizeEngine() {
        onboarding.updateModelStatus(
            Self.modelRowStatus(for: coordinator.enginePreparationState)
        )
    }

    private static func microphoneRowStatus(
        for status: AVAuthorizationStatus
    ) -> OnboardingRowStatus {
        switch status {
        case .authorized:
            .ready
        case .denied, .restricted:
            .actionRequired
        case .notDetermined:
            .pending
        @unknown default:
            .pending
        }
    }

    private static func modelRowStatus(
        for state: EnginePreparationState
    ) -> OnboardingRowStatus {
        switch state {
        case .ready:
            .ready
        case .failed:
            .actionRequired
        case .notStarted, .downloading, .warmingUp:
            .pending
        }
    }

    private func bounded(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}
