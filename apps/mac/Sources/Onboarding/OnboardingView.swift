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
    private weak var coordinator: DictationCoordinator?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator

        let resizer = OnboardingWindowResizer()
        let rootView = OnboardingView(
            coordinator: coordinator,
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

struct OnboardingView: View {
    // Every screen is the same size. The window used to grow from 430 to 648
    // when setup began, moving itself under the pointer at the exact moment
    // the user was reaching for something.
    private static let windowWidth: CGFloat = 460
    private static let windowHeight: CGFloat = 430

    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var permissions: OnboardingPermissionModel
    @State private var onboarding: OnboardingState
    @State private var flow = OnboardingFlow()

    private let windowResizer: OnboardingWindowResizer

    fileprivate init(
        coordinator: DictationCoordinator,
        windowResizer: OnboardingWindowResizer
    ) {
        let permissions = OnboardingPermissionModel()
        var onboarding = OnboardingState()
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
        _onboarding = State(initialValue: onboarding)
        self.windowResizer = windowResizer
    }

    var body: some View {
        VStack(spacing: 0) {
            stepBar
            Spacer(minLength: 10)
            stepBody
            Spacer(minLength: 10)
            footer
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .background(BrandUI.windowBg)
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

    // MARK: - chrome

    private var stepBar: some View {
        HStack(spacing: 10) {
            chevron(
                "chevron.left",
                enabled: flow.canGoBack,
                label: "back"
            ) {
                flow.goBack()
            }

            Spacer()

            // The dots are a control, not just an indicator. Going back to
            // check something should never mean walking the whole flow.
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
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.title)
                }
            }

            Spacer()

            chevron(
                "chevron.right",
                enabled: flow.canGoForward,
                label: "next"
            ) {
                flow.advance()
            }
        }
    }

    private func chevron(
        _ symbol: String,
        enabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(BrandUI.textSecondary)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .accessibilityLabel(label)
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

            Text(flow.step.title)
                .font(.system(size: 22, weight: .semibold))

            if flow.step == .hello {
                Text("escape the keyboard.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(BrandUI.gold)
            }

            Text(flow.step.reason)
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)

            switch flow.step {
            case .hello:
                EmptyView()
            case .model:
                modelProgress.padding(.top, 10)
            case .permissions:
                permissionRows.padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The download does not gate anything. It starts when the user says go and
    /// keeps running while they carry on — blocking the flow on 440 MB was the
    /// thing that made setup feel long.
    @ViewBuilder
    private var modelProgress: some View {
        switch coordinator.enginePreparationState {
        case let .downloading(progress):
            VStack(spacing: 7) {
                ProgressView(value: bounded(progress))
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("about 440 mb. carry on — this keeps going.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }
        case .warmingUp:
            Text("warming up…")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        case .ready:
            Text("already here.")
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

    private var permissionRows: some View {
        VStack(spacing: 0) {
            permissionRow(
                "microphone",
                status: onboarding.microphoneStatus,
                allow: {
                    permissions.requestMicrophoneAccess {
                        await coordinator.requestMicrophoneAccess()
                    }
                },
                openSettings: permissions.openMicrophoneSettings
            )

            Divider().overlay(BrandUI.hairline).padding(.vertical, 10)

            permissionRow(
                "accessibility",
                status: onboarding.accessibilityStatus,
                allow: permissions.requestAccessibilityPrompt,
                openSettings: permissions.openAccessibilitySettings
            )
        }
        .frame(maxWidth: 330)
    }

    /// Says what is true right now, in a word. The previous version showed
    /// three rows reading "pending" before consent had even been given, which
    /// reads as broken rather than waiting.
    private func permissionRow(
        _ name: String,
        status: OnboardingRowStatus,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .foregroundStyle(BrandUI.textPrimary)

            Spacer(minLength: 8)

            switch status {
            case .ready:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("granted")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(BrandUI.gold)
            case .actionRequired:
                Button("open settings", action: openSettings)
                    .font(.caption)
            case .pending:
                Button("allow", action: allow)
                    .font(.caption)
            }
        }
    }

    // MARK: - exactly one thing to do

    /// One button. There is no "skip" here and there should never have been
    /// one: the person launched the app in order to set it up, and macOS
    /// already gives them the way out — the window is `.closable`.
    ///
    /// Closing is also the *better* exit. It leaves `onboardingDismissed`
    /// false, so setup returns next launch, which is SPEC §5's rule that a
    /// broken setup gets the window back. The old link set that flag and
    /// silenced setup for good.
    private var footer: some View {
        Button(action: performPrimaryAction) {
            Text(flow.step.actionTitle)
                .frame(minWidth: 176)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func performPrimaryAction() {
        switch flow.step {
        case .hello:
            onboarding.consentToSetup()
            synchronizePermissions()
            // Kick the download off here so it runs underneath the rest of
            // setup rather than in front of it.
            coordinator.beginOnboardingEnginePreparation()
            flow.advance()

        case .model:
            flow.advance()

        case .permissions:
            coordinator.finishOnboarding()
        }
    }

    // MARK: - keeping the state in step with the system

    private func synchronizeOnboarding() {
        synchronizePermissions()
        synchronizeEngine()
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
