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
    // Every screen is the same size. The old flow grew from 430 to 648 when
    // setup began, which moved the window under the pointer at the exact
    // moment the user was reaching for something.
    private static let windowWidth: CGFloat = 460
    private static let windowHeight: CGFloat = 430

    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var permissions: OnboardingPermissionModel
    @State private var onboarding: OnboardingState
    @State private var flow = OnboardingFlow()
    @State private var hotkeyWasDetected = false

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
            Spacer(minLength: 12)
            stepBody
            Spacer(minLength: 12)
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
        .animation(.easeInOut(duration: 0.22), value: flow.step)
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
        // A granted permission is its own confirmation. Asking the user to
        // press "continue" after they have already watched it succeed is the
        // second button this redesign exists to remove.
        .task(id: "\(flow.step.rawValue)-\(isCurrentStepSatisfied)") {
            guard isCurrentStepSatisfied,
                  flow.step != .hello,
                  !flow.isLastStep else {
                return
            }
            try? await Task.sleep(for: .milliseconds(650))
            guard isCurrentStepSatisfied else {
                return
            }
            flow.advance()
        }
        .task(id: coordinator.hotkeyDetection?.sequence) {
            guard flow.step == .ready,
                  let detection = coordinator.hotkeyDetection else {
                return
            }
            hotkeyWasDetected = true
            try? await Task.sleep(for: .seconds(2))
            guard coordinator.hotkeyDetection?.sequence
                    == detection.sequence else {
                return
            }
            hotkeyWasDetected = false
        }
    }

    // MARK: - chrome

    private var stepBar: some View {
        HStack(spacing: 10) {
            Button {
                flow.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandUI.textSecondary)
            .opacity(flow.canGoBack ? 1 : 0)
            .disabled(!flow.canGoBack)
            .accessibilityLabel("back")

            Spacer()

            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases) { step in
                    Circle()
                        .fill(
                            step.rawValue <= flow.step.rawValue
                                ? BrandUI.gold
                                : BrandUI.textPrimary.opacity(0.18)
                        )
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityLabel(
                "step \(flow.position.index) of \(flow.position.total)"
            )

            Spacer()

            // Balances the chevron so the dots sit centred.
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0)
        }
    }

    // MARK: - the one idea on this screen

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
                .foregroundStyle(BrandUI.textPrimary)

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
                .frame(maxWidth: 320)

            stepDetail
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stepDetail: some View {
        switch flow.step {
        case .model:
            modelProgress
        case .ready:
            Text(hotkeyWasDetected ? "heard that." : " ")
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.gold)
        case .hello, .microphone, .accessibility:
            deniedHint
        }
    }

    /// Only appears when macOS has already refused. Until then the screen says
    /// one thing, which is the point.
    @ViewBuilder
    private var deniedHint: some View {
        let denied = (flow.step == .microphone
            && onboarding.microphoneStatus == .actionRequired)
            || (flow.step == .accessibility
                && onboarding.accessibilityStatus == .actionRequired)

        Text(denied ? "macOS is holding this one — turn it on in settings." : " ")
            .font(.caption)
            .foregroundStyle(denied ? BrandUI.attention : .clear)
    }

    @ViewBuilder
    private var modelProgress: some View {
        switch coordinator.enginePreparationState {
        case let .downloading(progress):
            VStack(spacing: 6) {
                ProgressView(value: bounded(progress))
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("about 440 mb, once.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }
        case .warmingUp:
            Text("warming up…")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        case .failed:
            Text("that download didn't finish.")
                .font(.caption)
                .foregroundStyle(BrandUI.attention)
        case .notStarted, .ready:
            Text(" ").font(.caption)
        }
    }

    // MARK: - exactly one thing to do

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: performPrimaryAction) {
                Text(primaryActionTitle)
                    .frame(minWidth: 176)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPrimaryActionBusy)

            // One way out, on one screen. A skip on every screen is another
            // competing action.
            if flow.step.offersSkip {
                Button("not now") {
                    coordinator.skipOnboarding()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
            } else {
                Text(" ").font(.caption)
            }
        }
    }

    private var primaryActionTitle: String {
        if flow.step == .microphone,
           onboarding.microphoneStatus == .actionRequired {
            return "open settings"
        }
        if flow.step == .accessibility,
           onboarding.accessibilityStatus == .actionRequired {
            return "open settings"
        }
        if flow.step == .model {
            switch coordinator.enginePreparationState {
            case .downloading, .warmingUp:
                return "downloading…"
            case .failed:
                return "try again"
            case .ready:
                return "continue"
            case .notStarted:
                return flow.step.actionTitle
            }
        }
        return flow.step.actionTitle
    }

    private var isPrimaryActionBusy: Bool {
        guard flow.step == .model else {
            return false
        }
        switch coordinator.enginePreparationState {
        case .downloading, .warmingUp:
            return true
        case .notStarted, .ready, .failed:
            return false
        }
    }

    private var isCurrentStepSatisfied: Bool {
        flow.isSatisfied(by: onboarding)
    }

    private func performPrimaryAction() {
        switch flow.step {
        case .hello:
            onboarding.consentToSetup()
            synchronizePermissions()
            flow.advance()

        case .microphone:
            if onboarding.microphoneStatus == .actionRequired {
                permissions.openMicrophoneSettings()
            } else {
                permissions.requestMicrophoneAccess {
                    await coordinator.requestMicrophoneAccess()
                }
            }

        case .accessibility:
            if onboarding.accessibilityStatus == .actionRequired {
                permissions.openAccessibilitySettings()
            } else {
                permissions.requestAccessibilityPrompt()
            }

        case .model:
            switch coordinator.enginePreparationState {
            case .ready:
                flow.advance()
            case .failed:
                coordinator.retryEnginePrewarm()
            case .notStarted:
                coordinator.beginOnboardingEnginePreparation()
            case .downloading, .warmingUp:
                break
            }

        case .ready:
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
