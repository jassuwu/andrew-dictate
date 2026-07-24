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
    private static let collapsedHeight: CGFloat = 430
    private static let expandedHeight: CGFloat = 735

    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var permissions: OnboardingPermissionModel
    @State private var onboarding: OnboardingState
    @State private var testedHotkey: DictationMode?

    private let detectedAgents: [DetectedAgentCLI]
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
        detectedAgents = AgentCLIDetector.detect()
        self.windowResizer = windowResizer
    }

    var body: some View {
        VStack(spacing: 0) {
            primarySetup
                .frame(height: 390)

            if onboarding.whileYouWaitVisible {
                whileYouWaitSection
                    .padding(.top, 14)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(
            width: 460,
            height: contentHeight,
            alignment: .top
        )
        .background(BrandUI.windowBg)
        .foregroundStyle(BrandUI.textPrimary)
        .font(BrandUI.bodyFont)
        .brandTinted()
        .controlSize(.small)
        .preferredColorScheme(.dark)
        .onAppear {
            permissions.refresh()
            synchronizeOnboarding()
            windowResizer.resize(
                to: contentHeight,
                animated: false
            )
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
        .onChange(of: onboarding.whileYouWaitVisible) { _, _ in
            windowResizer.resize(
                to: contentHeight,
                animated: true
            )
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
        .task(id: coordinator.hotkeyDetection?.sequence) {
            guard onboarding.whileYouWaitVisible,
                  let detection = coordinator.hotkeyDetection else {
                return
            }

            testedHotkey = detection.mode
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }
            guard coordinator.hotkeyDetection?.sequence
                    == detection.sequence else {
                return
            }
            testedHotkey = nil
        }
        .task(id: onboarding.autoFinishReady) {
            guard onboarding.autoFinishReady else {
                return
            }

            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }

            guard onboarding.finishAutomatically() else {
                return
            }
            coordinator.finishOnboarding()
        }
    }

    private var contentHeight: CGFloat {
        onboarding.whileYouWaitVisible
            ? Self.expandedHeight
            : Self.collapsedHeight
    }

    private var primarySetup: some View {
        VStack(spacing: 0) {
            header

            setupButtonSlot
                .padding(.top, 14)

            checklist
                .padding(.top, 14)
                .opacity(checklistIsActive ? 1 : 0.42)

            if !onboarding.whileYouWaitVisible {
                Text("keys and options live in settings.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                    .padding(.top, 10)
            }

            Spacer(minLength: 6)

            Button("skip for now") {
                guard onboarding.skipForNow() else {
                    return
                }
                coordinator.skipOnboarding()
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
    }

    private var whileYouWaitSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                BrandSectionHeader("while you wait")

                Spacer()

                Text("optional")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }
            .padding(.horizontal, 2)

            BrandCard {
                VStack(alignment: .leading, spacing: 11) {
                    hotkeyTestRow
                    cardDivider

                    SettingsToggleRow(
                        "pre-roll",
                        explanation:
                            "keeps a short microphone buffer warm "
                            + "to protect the first word.",
                        isOn: $settings.preRollEnabled
                    )
                    cardDivider

                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("agent cli")
                            .font(BrandUI.bodyFont.weight(.medium))
                            .frame(width: 70, alignment: .leading)

                        AgentCLIEditor(
                            settings: settings,
                            detectedAgents: detectedAgents,
                            onEditingChanged: {
                                onboarding
                                    .setOptionalConfigurationEditing($0)
                            }
                        )
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    }
                    cardDivider

                    SettingsToggleRow(
                        "spoken answers",
                        explanation:
                            "reads ask answers aloud in two short "
                            + "spoken sentences.",
                        isOn: $settings.voiceAnswersEnabled
                    )
                }
            }
        }
    }

    private var hotkeyTestRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("press to test")
                    .font(BrandUI.bodyFont.weight(.medium))

                Text(
                    testedHotkey == nil
                        ? "try either hold key"
                        : "\(testedHotkey!.rawValue) detected"
                )
                .font(.caption)
                .foregroundStyle(
                    testedHotkey == nil
                        ? BrandUI.textSecondary
                        : BrandUI.gold
                )
            }

            Spacer(minLength: 8)

            ForEach(DictationMode.allCases, id: \.self) { mode in
                VStack(spacing: 3) {
                    KeyChip(
                        settings.hotkeyBinding(for: mode).displayName,
                        isActive: testedHotkey == mode
                    )

                    Text(mode.rawValue)
                        .font(.caption2)
                        .foregroundStyle(BrandUI.textSecondary)
                }
            }
        }
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(BrandUI.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(spacing: 5) {
            Image("Badge")
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            Text("Andrew Dictate")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(BrandUI.textPrimary)

            Text("escape the keyboard.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(BrandUI.gold)

            Text(
                onboarding.autoFinishArmed
                    ? "ready — hold fn and speak."
                    : "hold fn, talk, get text — everything stays on this mac."
            )
            .font(.caption)
            .foregroundStyle(
                onboarding.autoFinishArmed
                    ? BrandUI.textPrimary
                    : BrandUI.textSecondary
            )
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var setupButtonSlot: some View {
        if !onboarding.consented && !onboarding.autoFinishArmed {
            Button("set up Andrew Dictate", action: beginSetup)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(BrandUI.windowBg)
                .padding(.horizontal, 22)
                .frame(height: 34)
                .background(
                    BrandUI.gold,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            microphoneRow
            Divider()
                .overlay(BrandUI.hairline)
            accessibilityRow
            Divider()
                .overlay(BrandUI.hairline)
            modelRow
        }
        .padding(.horizontal, 12)
        .background(
            BrandUI.cardBg,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandUI.hairline, lineWidth: 1)
        }
        .allowsHitTesting(checklistIsActive)
    }

    private var microphoneRow: some View {
        checklistRow("microphone") {
            switch visibleMicrophoneStatus {
            case .pending:
                pendingText("pending")
            case .actionRequired:
                actionStatus("denied") {
                    permissions.openMicrophoneSettings()
                }
            case .ready:
                readyText("granted ✓")
            }
        }
    }

    private var accessibilityRow: some View {
        checklistRow("accessibility") {
            switch visibleAccessibilityStatus {
            case .pending:
                pendingText("pending")
            case .actionRequired:
                actionStatus("not yet") {
                    permissions.openAccessibilitySettings()
                }
            case .ready:
                readyText("granted ✓")
            }
        }
    }

    private var modelRow: some View {
        checklistRow("speech model") {
            switch coordinator.enginePreparationState {
            case .notStarted:
                pendingText("pending")

            case let .downloading(progress):
                HStack(spacing: 8) {
                    ProgressView(value: bounded(progress))
                        .progressViewStyle(.linear)
                        .tint(BrandUI.gold)
                        .frame(width: 92)

                    Text("\(Int(bounded(progress) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(BrandUI.gold)
                        .frame(width: 34, alignment: .trailing)
                }

            case .warmingUp:
                pendingText("warming up")

            case .ready:
                readyText("ready ✓")

            case .failed:
                actionStatus("failed") {
                    coordinator.retryEnginePrewarm()
                } actionTitle: {
                    Text("retry")
                }
            }
        }
    }

    private func checklistRow<Status: View>(
        _ label: String,
        @ViewBuilder status: () -> Status
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout.weight(.medium))

            Spacer(minLength: 10)

            status()
        }
        .frame(height: 43)
    }

    private func pendingText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(BrandUI.textSecondary)
    }

    private func readyText(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(BrandUI.textPrimary)
    }

    private func actionStatus<ActionTitle: View>(
        _ text: String,
        action: @escaping () -> Void,
        @ViewBuilder actionTitle: () -> ActionTitle
    ) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(BrandUI.gold)

            Button(action: action, label: actionTitle)
                .buttonStyle(.link)
                .controlSize(.small)
                .tint(BrandUI.gold)
        }
    }

    private func actionStatus(
        _ text: String,
        action: @escaping () -> Void
    ) -> some View {
        actionStatus(text, action: action) {
            Text("open settings")
        }
    }

    private var checklistIsActive: Bool {
        onboarding.consented || onboarding.autoFinishArmed
    }

    private var visibleMicrophoneStatus: OnboardingRowStatus {
        checklistIsActive ? onboarding.microphoneStatus : .pending
    }

    private var visibleAccessibilityStatus: OnboardingRowStatus {
        checklistIsActive ? onboarding.accessibilityStatus : .pending
    }

    private func beginSetup() {
        guard onboarding.consentToSetup() else {
            return
        }

        synchronizePermissions()
        coordinator.beginOnboardingEnginePreparation()
        permissions.requestMicrophoneAccess {
            await coordinator.requestMicrophoneAccess()
        }
        permissions.requestAccessibilityPrompt()
    }

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
