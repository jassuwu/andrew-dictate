import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import SwiftUI

@MainActor
final class OnboardingWindowController:
    NSWindowController,
    NSWindowDelegate
{
    private weak var coordinator: DictationCoordinator?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator

        let rootView = OnboardingView(coordinator: coordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
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
    private static let background = Color(
        red: 0x1B / 255,
        green: 0x1B / 255,
        blue: 0x1F / 255
    )
    private static let cream = Color(
        red: 0xF9 / 255,
        green: 0xE9 / 255,
        blue: 0xA8 / 255
    )
    private static let gold = Color(
        red: 0xE5 / 255,
        green: 0xBE / 255,
        blue: 0x62 / 255
    )

    @ObservedObject private var coordinator: DictationCoordinator
    @StateObject private var permissions: OnboardingPermissionModel
    @State private var onboarding: OnboardingState

    init(coordinator: DictationCoordinator) {
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
        _permissions = StateObject(wrappedValue: permissions)
        _onboarding = State(initialValue: onboarding)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            setupButtonSlot
                .padding(.top, 14)

            checklist
                .padding(.top, 14)
                .opacity(checklistIsActive ? 1 : 0.42)

            Text("keys and options live in settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)

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
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(width: 460, height: 430)
        .background(Self.background)
        .preferredColorScheme(.dark)
        .onAppear {
            permissions.refresh()
            synchronizeOnboarding()
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
        .task(id: onboarding.autoFinishArmed) {
            guard onboarding.autoFinishArmed else {
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

    private var header: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            Text("Andrew Dictate")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Self.cream)

            Text("escape the keyboard.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Self.gold)

            Text(
                onboarding.autoFinishArmed
                    ? "ready — hold fn and speak."
                    : "hold fn, talk, get text — everything stays on this mac."
            )
            .font(.caption)
            .foregroundStyle(
                onboarding.autoFinishArmed
                    ? Self.cream
                    : Color.secondary
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
                .foregroundStyle(Self.background)
                .padding(.horizontal, 22)
                .frame(height: 34)
                .background(
                    Self.gold,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            microphoneRow
            Divider()
                .overlay(Self.cream.opacity(0.12))
            accessibilityRow
            Divider()
                .overlay(Self.cream.opacity(0.12))
            modelRow
        }
        .padding(.horizontal, 12)
        .background(
            Self.cream.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12)
        )
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
                        .tint(Self.gold)
                        .frame(width: 92)

                    Text("\(Int(bounded(progress) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Self.gold)
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
            .foregroundStyle(.secondary)
    }

    private func readyText(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Self.cream)
    }

    private func actionStatus<ActionTitle: View>(
        _ text: String,
        action: @escaping () -> Void,
        @ViewBuilder actionTitle: () -> ActionTitle
    ) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Self.gold)

            Button(action: action, label: actionTitle)
                .buttonStyle(.link)
                .controlSize(.small)
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
