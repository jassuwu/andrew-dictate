import SwiftUI

struct SettingsToggleRow: View {
    let title: String
    let explanation: String
    @Binding var isOn: Bool

    init(
        _ title: String,
        explanation: String,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.explanation = explanation
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BrandUI.bodyFont.weight(.medium))
                    .foregroundStyle(BrandUI.textPrimary)

                Text(explanation)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .brandToggleStyle()
        }
    }
}

struct AgentCLIEditor: View {
    private static let customSelection = "custom"
    private static let noSelection = "none"

    @ObservedObject private var settings: AppSettings
    private let detectedAgents: [DetectedAgentCLI]
    private let onEditingChanged: (Bool) -> Void

    @State private var selectedAgent: String
    @State private var customAgentTemplate: String
    @State private var customTemplateIsInvalid = false
    @FocusState private var customTemplateIsFocused: Bool

    init(
        settings: AppSettings,
        detectedAgents: [DetectedAgentCLI],
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _settings = ObservedObject(wrappedValue: settings)
        self.detectedAgents = detectedAgents
        self.onEditingChanged = onEditingChanged
        _selectedAgent = State(
            initialValue: Self.initialSelection(
                template: settings.agentCommandTemplate,
                detectedAgents: detectedAgents
            )
        )
        _customAgentTemplate = State(
            initialValue: settings.agentCommandTemplate
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("", selection: $selectedAgent) {
                ForEach(detectedAgents) { detected in
                    Text(
                        detected.cli == .codex
                            ? "codex (recommended)"
                            : detected.cli.rawValue
                    )
                    .tag(selection(for: detected.cli))
                    .help(detected.executableURL.path)
                }

                Text("custom")
                    .tag(Self.customSelection)

                Text("none")
                    .tag(Self.noSelection)
            }
            .labelsHidden()
            .brandMenuStyle()
            .onChange(of: selectedAgent) { _, newSelection in
                applySelection(newSelection)
            }

            if selectedAgent == Self.customSelection {
                TextField(
                    "command containing {prompt}",
                    text: $customAgentTemplate
                )
                .font(BrandUI.valueFont)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                    .fill(BrandUI.windowBg)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                    .stroke(
                        customTemplateIsInvalid
                            ? BrandUI.gold
                            : BrandUI.hairline,
                        lineWidth: 1
                    )
                }
                .focused($customTemplateIsFocused)
                .onChange(of: customAgentTemplate) { _, template in
                    let isValid = AgentCommandTemplate.isValid(template)
                    customTemplateIsInvalid = !isValid
                    if isValid {
                        settings.agentCommandTemplate = template
                    }
                }

                if customTemplateIsInvalid {
                    Text("{prompt} must be a standalone word")
                        .font(.caption)
                        .foregroundStyle(BrandUI.gold)
                }
            }
        }
        .onChange(of: customTemplateIsFocused) { _, isFocused in
            onEditingChanged(isFocused)
        }
        .onDisappear {
            onEditingChanged(false)
        }
    }

    private func applySelection(_ selection: String) {
        if selection == Self.noSelection {
            customTemplateIsInvalid = false
            settings.agentCommandTemplate = ""
            return
        }

        guard selection != Self.customSelection else {
            if AgentCommandTemplate.isValid(customAgentTemplate) {
                settings.agentCommandTemplate = customAgentTemplate
            }
            return
        }

        guard let detected = detectedAgents.first(where: {
            self.selection(for: $0.cli) == selection
        }) else {
            return
        }

        customTemplateIsInvalid = false
        settings.agentCommandTemplate = detected.cli.commandTemplate
    }

    private func selection(for cli: AgentCLI) -> String {
        "cli.\(cli.rawValue)"
    }

    private static func initialSelection(
        template: String,
        detectedAgents: [DetectedAgentCLI]
    ) -> String {
        guard !template.isEmpty else {
            return noSelection
        }
        guard let cli = AgentCLI.allCases.first(where: {
            $0.commandTemplate == template
        }), detectedAgents.contains(where: { $0.cli == cli }) else {
            return customSelection
        }
        return "cli.\(cli.rawValue)"
    }
}
