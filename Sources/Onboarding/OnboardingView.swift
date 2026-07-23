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
        window.setContentSize(NSSize(width: 680, height: 640))
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
    @Published private(set) var microphoneGranted: Bool
    @Published private(set) var accessibilityGranted: Bool

    private var accessibilityPromptTriggered = false

    init() {
        microphoneGranted =
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    func refresh() {
        microphoneGranted =
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        refreshAccessibility()
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestMicrophone() {
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            self?.microphoneGranted = granted
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

    @State private var flow = OnboardingFlowState()
    @State private var detectedAgents: [DetectedAgentCLI]
    @State private var selectedAgent: String
    @State private var customAgentTemplate: String
    @State private var customTemplateIsInvalid = false
    @State private var flashedHotkey: HotkeyDetection?

    init(coordinator: DictationCoordinator) {
        let detectedAgents = AgentCLIDetector.detect()
        let settings = coordinator.settings

        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: settings)
        _permissions = StateObject(
            wrappedValue: OnboardingPermissionModel()
        )
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
            progressHeader

            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 54)
                .padding(.vertical, 34)

            Divider()

            navigation
        }
        .frame(width: 680, height: 640)
        .onAppear {
            permissions.refresh()
            synchronizeFlow()
        }
        .onChange(of: permissions.microphoneGranted) {
            synchronizePermissions()
        }
        .onChange(of: permissions.accessibilityGranted) {
            synchronizePermissions()
        }
        .onChange(of: coordinator.enginePreparationState) {
            flow.updateEngineReady(
                coordinator.enginePreparationState.isReady
            )
        }
        .onChange(of: coordinator.hotkeyDetection) {
            flash(coordinator.hotkeyDetection)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 14) {
            Text("Andrew Dictate")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            Text("step \(flow.step.rawValue + 1) of 4")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(
                            step.rawValue <= flow.step.rawValue
                                ? Color.primary.opacity(0.65)
                                : Color.primary.opacity(0.12)
                        )
                        .frame(width: 22, height: 3)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .welcome:
            welcomeStep
        case .permissions:
            permissionsStep
        case .model:
            modelStep
        case .keysAndAgent:
            keysAndAgentStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("Andrew Dictate")
                .font(.system(size: 38, weight: .semibold))

            Text(
                "hold a key, talk, get text — everything stays on this mac."
            )
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer()
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepTitle(
                "permissions",
                detail: "two permissions make hold-to-talk work anywhere."
            )

            VStack(spacing: 14) {
                permissionRow(
                    title: "microphone",
                    reason: "to hear you while you hold the key",
                    granted: permissions.microphoneGranted,
                    action: permissions.requestMicrophone
                )

                permissionRow(
                    title: "accessibility",
                    reason: "to paste the transcript where you’re typing",
                    granted: permissions.accessibilityGranted,
                    action: permissions.requestAccessibility
                )
            }

            Button("skip for now") {
                flow.skipPermissions()
                _ = flow.advance()
            }
            .buttonStyle(.link)
            .controlSize(.small)

            Spacer()
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

    private func permissionRow(
        title: String,
        reason: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(granted ? "granted" : "not yet")
                .font(.caption)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 58, alignment: .trailing)

            Button(granted ? "granted" : "grant", action: action)
                .disabled(granted)
                .frame(width: 72)
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            stepTitle(
                "local model",
                detail: "speech recognition downloads once and stays on this mac."
            )

            VStack(alignment: .leading, spacing: 13) {
                switch coordinator.enginePreparationState {
                case let .downloading(progress):
                    Text("downloading \(modelDescription)")
                    .font(.headline)

                    ProgressView(value: progress)

                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                case .warmingUp:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("warming up")
                            .font(.headline)
                    }

                case .ready:
                    Text("ready")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text(
                        "\(modelName) is warm and ready for dictation."
                    )
                        .foregroundStyle(.secondary)

                case .failed:
                    Text("couldn’t prepare the model")
                        .font(.headline)
                    Text("check your connection and try again.")
                        .foregroundStyle(.secondary)
                    Button("try again") {
                        coordinator.retryEnginePrewarm()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 12)
            )

            Spacer()
        }
    }

    private var keysAndAgentStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stepTitle(
                    "keys & agent",
                    detail: "try the keys, then choose how command prompts run."
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("keys")
                        .font(.headline)

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
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("pre-roll")
                        .font(.headline)

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

                VStack(alignment: .leading, spacing: 10) {
                    Text("agent cli")
                        .font(.headline)
                    agentEditor
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func hotkeyRow(for mode: DictationMode) -> some View {
        let isDetected = flashedHotkey?.mode == mode

        return HStack(spacing: 14) {
            Text("\(mode.rawValue) key")

            Spacer()

            Text(settings.hotkeyBinding(for: mode).displayName)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6)
                )

            Text(isDetected ? "detected" : "press to test")
                .font(.caption)
                .foregroundStyle(isDetected ? .green : .secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
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
            HStack(alignment: .top, spacing: 11) {
                radioIndicator(isSelected: settings.preRollEnabled == enabled)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10)
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
        VStack(alignment: .leading, spacing: 6) {
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
            .onChange(of: selectedAgent) {
                applyAgentSelection(selectedAgent)
            }

            if selectedAgent == Self.customAgentSelection {
                TextField(
                    "command containing {prompt}",
                    text: $customAgentTemplate
                )
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

    private func stepTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private var navigation: some View {
        HStack {
            if flow.step != .welcome {
                Button("back") {
                    flow.goBack()
                }
            }

            Spacer()

            Button(continueButtonTitle) {
                if flow.step == .keysAndAgent {
                    coordinator.finishOnboarding()
                } else {
                    _ = flow.advance()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!flow.canContinue)
        }
        .padding(.horizontal, 24)
        .frame(height: 66)
    }

    private var continueButtonTitle: String {
        switch flow.step {
        case .welcome:
            "get started"
        case .permissions, .model:
            "continue"
        case .keysAndAgent:
            "finish"
        }
    }

    private var modelName: String {
        switch settings.engineVersion {
        case .v2:
            "parakeet v2"
        case .v3:
            "parakeet v3"
        }
    }

    private var modelDescription: String {
        switch settings.engineVersion {
        case .v2:
            "parakeet v2 (~450mb, one time)"
        case .v3:
            "parakeet v3 (one time)"
        }
    }

    private func synchronizeFlow() {
        synchronizePermissions()
        flow.updateEngineReady(
            coordinator.enginePreparationState.isReady
        )
    }

    private func synchronizePermissions() {
        flow.updatePermissions(
            microphoneGranted: permissions.microphoneGranted,
            accessibilityGranted: permissions.accessibilityGranted
        )
    }

    private func flash(_ detection: HotkeyDetection?) {
        guard flow.step == .keysAndAgent,
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
