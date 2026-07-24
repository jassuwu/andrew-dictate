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
        window.setContentSize(NSSize(width: 520, height: 640))
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

    var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    var microphoneActionTitle: String {
        microphoneStatus == .denied ? "open settings" : "grant"
    }

    init() {
        microphoneStatus =
            AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func refresh() {
        microphoneStatus =
            AVCaptureDevice.authorizationStatus(for: .audio)
        refreshAccessibility()
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func performMicrophoneAction(
        requestAccess: @escaping @MainActor () async -> Bool
    ) {
        if microphoneStatus == .denied {
            guard let url = URL(
                string:
                    "x-apple.systempreferences:"
                        + "com.apple.preference.security?Privacy_Microphone"
            ) else {
                return
            }
            NSWorkspace.shared.open(url)
            return
        }

        Task { @MainActor [weak self] in
            _ = await requestAccess()
            self?.microphoneStatus =
                AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func requestAccessibility() {
        if !accessibilityPromptTriggered {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:
                    true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            accessibilityPromptTriggered = true
        }

        guard let url = URL(
            string:
                "x-apple.systempreferences:"
                    + "com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct OnboardingView: View {
    private static let customAgentSelection = "custom"
    private static let noAgentSelection = "none"

    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @StateObject private var permissions: OnboardingPermissionModel

    @State private var onboarding = OnboardingState()
    @State private var detectedAgents: [DetectedAgentCLI]
    @State private var selectedAgent: String
    @State private var customAgentTemplate: String
    @State private var customTemplateIsInvalid = false
    @State private var flashedHotkey: HotkeyDetection?

    init(coordinator: DictationCoordinator) {
        let detectedAgents = AgentCLIDetector.detect()
        let settings = coordinator.settings
        let permissions = OnboardingPermissionModel()
        var onboarding = OnboardingState()
        onboarding.updatePermissions(
            microphoneGranted: permissions.microphoneGranted,
            accessibilityGranted: permissions.accessibilityGranted
        )
        onboarding.updateEngine(
            preparationStarted:
                coordinator.enginePreparationState != .notStarted,
            ready: coordinator.enginePreparationState.isReady
        )

        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: settings)
        _permissions = StateObject(
            wrappedValue: permissions
        )
        _onboarding = State(initialValue: onboarding)
        _detectedAgents = State(initialValue: detectedAgents)
        _selectedAgent = State(
            initialValue: Self.initialAgentSelection(
                template: settings.agentCommandTemplate,
                detectedAgents: detectedAgents
            )
        )
        _customAgentTemplate = State(
            initialValue: settings.agentCommandTemplate
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                permissionsSection

                Divider()

                keysAndOptionsSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .disabled(!onboarding.sectionsEnabled)
            .opacity(onboarding.sectionsEnabled ? 1 : 0.42)

            Spacer(minLength: 4)

            Divider()

            persistentModelStatus
                .disabled(!onboarding.sectionsEnabled)
                .opacity(onboarding.sectionsEnabled ? 1 : 0.42)

            Divider()

            completionBar
        }
        .frame(width: 520, height: 640)
        .onAppear {
            permissions.refresh()
            synchronizeOnboarding()
            coordinator.onboardingSectionsDidChange(
                enabled: onboarding.sectionsEnabled
            )
        }
        .onChange(of: onboarding.sectionsEnabled) {
            coordinator.onboardingSectionsDidChange(
                enabled: onboarding.sectionsEnabled
            )
        }
        .onChange(of: permissions.microphoneGranted) {
            synchronizePermissions()
        }
        .onChange(of: permissions.accessibilityGranted) {
            synchronizePermissions()
        }
        .onChange(of: coordinator.enginePreparationState) {
            synchronizeEngine()
        }
        .onChange(of: coordinator.hotkeyDetection) {
            flash(coordinator.hotkeyDetection)
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
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Andrew Dictate")
                    .font(.system(size: 27, weight: .semibold))

                Text("escape the keyboard.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(red: 0xE4 / 255, green: 0x59 / 255, blue: 0x3B / 255))

                Text(
                    "hold a key, talk, get text — dictation stays on this mac."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if shouldShowStartSetup {
                Button("start setup") {
                    onboarding.consentToSetup()
                    coordinator.onboardingSectionsDidChange(enabled: true)
                    coordinator.beginOnboardingEnginePreparation()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 88)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("permissions")

            HStack(spacing: 10) {
                permissionRow(
                    title: "microphone",
                    reason: "to hear you while you hold the key",
                    granted: permissions.microphoneGranted,
                    actionTitle: permissions.microphoneActionTitle,
                    action: {
                        permissions.performMicrophoneAction {
                            await coordinator.requestMicrophoneAccess()
                        }
                    }
                )

                permissionRow(
                    title: "accessibility",
                    reason: "to paste the transcript where you’re typing",
                    granted: permissions.accessibilityGranted,
                    action: permissions.requestAccessibility
                )
            }
        }
    }

    private func permissionRow(
        title: String,
        reason: String,
        granted: Bool,
        actionTitle: String = "grant",
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)

                Spacer()

                Text(granted ? "granted" : "not yet")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .secondary)
            }

            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button(
                granted ? "granted" : actionTitle,
                action: action
            )
            .disabled(granted)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 86)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var keysAndOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("keys & options")

            HStack(alignment: .top, spacing: 12) {
                keyBindings
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                preRollOptions
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            agentOptions
        }
    }

    private var keyBindings: some View {
        VStack(alignment: .leading, spacing: 6) {
            optionTitle("keys")

            hotkeyRow(for: .dictation)
            hotkeyRow(for: .command)

            if let keyboardSettingsURL = URL(
                string:
                    "x-apple.systempreferences:"
                        + "com.apple.Keyboard-Settings.extension"
            ) {
                Link(
                    "set fn to “do nothing” in keyboard settings",
                    destination: keyboardSettingsURL
                )
                .font(.caption)
                .lineLimit(2)
            }
        }
    }

    private var preRollOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            optionTitle("pre-roll")

            preRollRow(
                enabled: false,
                title: "off",
                detail: "mic only while holding a key"
            )
            preRollRow(
                enabled: true,
                title: "on",
                detail:
                    "never lose your first word — keeps the mic warm "
                        + "while the app runs"
            )
        }
    }

    private var agentOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            optionTitle("agent cli")
            agentEditor
        }
    }

    private func hotkeyRow(for mode: DictationMode) -> some View {
        let isDetected = flashedHotkey?.mode == mode

        return HStack(spacing: 8) {
            Text("\(mode.rawValue) key")
                .lineLimit(1)

            Spacer(minLength: 2)

            Text(settings.hotkeyBinding(for: mode).displayName)
                .font(.system(.callout, design: .monospaced, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 5)
                )

            Text(isDetected ? "detected" : "press to test")
                .font(.caption2)
                .foregroundStyle(isDetected ? .green : .secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func preRollRow(
        enabled: Bool,
        title: String,
        detail: String
    ) -> some View {
        Button {
            settings.preRollEnabled = enabled
        } label: {
            HStack(alignment: .top, spacing: 9) {
                radioIndicator(isSelected: settings.preRollEnabled == enabled)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func radioIndicator(isSelected: Bool) -> some View {
        Circle()
            .stroke(.secondary, lineWidth: 1)
            .frame(width: 14, height: 14)
            .overlay {
                if isSelected {
                    Circle()
                        .fill(.primary)
                        .frame(width: 7, height: 7)
                }
            }
    }

    private var agentEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("agent cli", selection: $selectedAgent) {
                ForEach(detectedAgents) { detected in
                    Text(
                        detected.cli == .codex
                            ? "codex (recommended)"
                            : detected.cli.rawValue
                    )
                    .tag(agentSelection(for: detected.cli))
                    .help(detected.executableURL.path)
                }

                Text("custom")
                    .tag(Self.customAgentSelection)

                Text("none")
                    .tag(Self.noAgentSelection)
            }
            .labelsHidden()
            .controlSize(.small)
            .onChange(of: selectedAgent) {
                applyAgentSelection(selectedAgent)
            }

            if selectedAgent == Self.customAgentSelection {
                TextField(
                    "command containing {prompt}",
                    text: $customAgentTemplate
                )
                .controlSize(.small)
                .onChange(of: customAgentTemplate) {
                    let isValid = AgentCommandTemplate.isValid(
                        customAgentTemplate
                    )
                    customTemplateIsInvalid = !isValid
                    if isValid {
                        settings.agentCommandTemplate = customAgentTemplate
                    }
                }

                if customTemplateIsInvalid {
                    Text("{prompt} must be a standalone word")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
    }

    private func optionTitle(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
    }

    @ViewBuilder
    private var persistentModelStatus: some View {
        HStack(spacing: 10) {
            switch coordinator.enginePreparationState {
            case .notStarted:
                Text("model waiting for setup")
                    .foregroundStyle(.secondary)

            case let .downloading(progress):
                ProgressView(value: progress)
                    .frame(width: 150)

                Text("downloading model…")
                    .foregroundStyle(.secondary)

                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

            case .warmingUp:
                ProgressView()
                    .controlSize(.small)

                Text("warming up model…")
                    .foregroundStyle(.secondary)

            case .ready:
                Text("model ready ✓")
                    .foregroundStyle(.green)

            case .failed:
                Text("model download failed")
                    .foregroundStyle(.secondary)

                Button("retry") {
                    coordinator.retryEnginePrewarm()
                }
                .controlSize(.small)
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 22)
        .frame(height: 48)
    }

    private var completionBar: some View {
        HStack(spacing: 10) {
            Button("skip for now") {
                guard onboarding.skipForNow() else {
                    return
                }
                coordinator.skipOnboarding()
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .disabled(!onboarding.sectionsEnabled)

            Spacer(minLength: 0)

            if !onboarding.finishEnabled {
                Text(finishDisabledHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Button("finish") {
                guard onboarding.finish() else {
                    return
                }
                coordinator.finishOnboarding()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!onboarding.finishEnabled)
            .help(
                onboarding.finishEnabled
                    ? "finish setup"
                    : finishDisabledHint
            )
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private var shouldShowStartSetup: Bool {
        coordinator.enginePreparationState == .notStarted
            && !onboarding.setupConsented
    }

    private var finishDisabledHint: String {
        let items = onboarding.missingItems.map(\.rawValue)
        return "waiting on: \(items.joined(separator: ", "))"
    }

    private func synchronizeOnboarding() {
        synchronizePermissions()
        synchronizeEngine()
    }

    private func synchronizePermissions() {
        onboarding.updatePermissions(
            microphoneGranted: permissions.microphoneGranted,
            accessibilityGranted: permissions.accessibilityGranted
        )
    }

    private func synchronizeEngine() {
        onboarding.updateEngine(
            preparationStarted:
                coordinator.enginePreparationState != .notStarted,
            ready: coordinator.enginePreparationState.isReady
        )
    }

    private func flash(_ detection: HotkeyDetection?) {
        guard onboarding.sectionsEnabled,
              let detection else {
            return
        }

        flashedHotkey = detection
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            if flashedHotkey?.sequence == detection.sequence {
                flashedHotkey = nil
            }
        }
    }

    private func applyAgentSelection(_ selection: String) {
        if selection == Self.noAgentSelection {
            customTemplateIsInvalid = false
            settings.agentCommandTemplate = ""
            return
        }

        guard selection != Self.customAgentSelection else {
            if AgentCommandTemplate.isValid(customAgentTemplate) {
                settings.agentCommandTemplate = customAgentTemplate
            }
            return
        }

        guard let detected = detectedAgents.first(where: {
            agentSelection(for: $0.cli) == selection
        }) else {
            return
        }

        customTemplateIsInvalid = false
        settings.agentCommandTemplate = detected.cli.commandTemplate
    }

    private func agentSelection(for cli: AgentCLI) -> String {
        "cli.\(cli.rawValue)"
    }

    private static func initialAgentSelection(
        template: String,
        detectedAgents: [DetectedAgentCLI]
    ) -> String {
        guard !template.isEmpty else {
            return noAgentSelection
        }
        guard let cli = AgentCLI.allCases.first(where: {
            $0.commandTemplate == template
        }), detectedAgents.contains(where: { $0.cli == cli }) else {
            return customAgentSelection
        }
        return "cli.\(cli.rawValue)"
    }
}
