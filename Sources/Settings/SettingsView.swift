import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController {
    init(coordinator: DictationCoordinator) {
        let rootView = SettingsView(coordinator: coordinator)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "settings"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.setContentSize(NSSize(width: 560, height: 720))
        window.minSize = NSSize(width: 540, height: 560)
        window.isReleasedWhenClosed = false
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

struct SettingsView: View {
    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var dictionaryStore: DictionaryStore
    @ObservedObject private var customActionStore: CustomActionStore
    @StateObject private var loginItem = LoginItemController()

    private let modelStore: ModelStore

    @State private var detectedAgents: [DetectedAgentCLI]
    @State private var installedTerminals: [TerminalOption]
    @State private var installedModels: [InstalledModel] = []
    @State private var pendingModelRemoval: EngineVersion?
    @State private var modelStoreMessage: String?

    init(coordinator: DictationCoordinator) {
        let settings = coordinator.settings
        let detectedAgents = AgentCLIDetector.detect()
        let installedTerminals = TerminalDetector.detectInstalled()

        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: settings)
        _dictionaryStore = ObservedObject(
            wrappedValue: coordinator.dictionaryStore
        )
        _customActionStore = ObservedObject(
            wrappedValue: coordinator.customActionStore
        )
        modelStore = ModelStore(
            activeVersion: { coordinator.activeEngineVersion }
        )
        _detectedAgents = State(initialValue: detectedAgents)
        _installedTerminals = State(initialValue: installedTerminals)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identityStrip

                settingsSection("keys") {
                    VStack(alignment: .leading, spacing: 12) {
                        hotkeyRow(for: .dictation)
                        cardDivider
                        hotkeyRow(for: .command)
                    }
                }

                settingsSection("dictation & ask") {
                    VStack(alignment: .leading, spacing: 13) {
                        SettingsToggleRow(
                            "pre-roll",
                            explanation:
                                "keeps a short microphone buffer warm "
                                + "to protect the first word.",
                            isOn: $settings.preRollEnabled
                        )
                        cardDivider
                        SettingsToggleRow(
                            "sound feedback",
                            explanation:
                                "plays a subtle cue when listening starts "
                                + "and stops.",
                            isOn: $settings.soundFeedbackEnabled
                        )
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

                settingsSection("engine") {
                    engineEditor
                }

                settingsSection("dictionary") {
                    DictionaryEditor(store: dictionaryStore)
                }

                settingsSection("actions") {
                    CustomActionEditor(store: customActionStore)
                }

                settingsSection("command mode") {
                    commandModeEditor
                }

                settingsSection("general") {
                    SettingsToggleRow(
                        "launch at login",
                        explanation:
                            "starts Andrew Dictate when you sign in.",
                        isOn: Binding(
                            get: { loginItem.isEnabled },
                            set: { loginItem.setEnabled($0) }
                        )
                    )

                    if let message = loginItem.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(BrandUI.textSecondary)
                            .padding(.top, 6)
                    }
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .background(BrandUI.windowBg)
        .foregroundStyle(BrandUI.textPrimary)
        .font(BrandUI.bodyFont)
        .brandTinted()
        .controlSize(.small)
        .frame(minWidth: 540, minHeight: 560)
        .preferredColorScheme(.dark)
        .onAppear {
            loginItem.refresh()
            selectAvailableTerminalIfNeeded()
            refreshInstalledModels()
        }
        .onChange(of: coordinator.enginePreparationState) { _, state in
            if state == .ready || state == .failed {
                refreshInstalledModels()
            }
        }
        .alert(item: $pendingModelRemoval) { version in
            let isActive = version == coordinator.activeEngineVersion
            return Alert(
                title: Text(
                    isActive
                        ? "remove the active model?"
                        : "remove parakeet \(version.rawValue) download?"
                ),
                message: Text(
                    isActive
                        ? "dictation will stop working until it downloads "
                            + "again. it re-downloads the next time you "
                            + "dictate or when you select it here. other "
                            + "apps using FluidAudio models (like Hex) "
                            + "share this storage."
                        : "it will re-download if selected again. "
                            + "other apps using FluidAudio models (like Hex) "
                            + "share this storage and may re-download it too."
                ),
                primaryButton: .destructive(Text("remove download")) {
                    removeDownload(version)
                },
                secondaryButton: .cancel(Text("cancel"))
            )
        }
    }

    private var identityStrip: some View {
        HStack(spacing: 12) {
            Image("Badge")
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            Text("Andrew Dictate")
                .font(BrandUI.titleFont)
                .foregroundStyle(BrandUI.textPrimary)

            Spacer(minLength: 12)

            Text("v\(shortVersion)")
                .font(BrandUI.valueFont)
                .foregroundStyle(BrandUI.textSecondary)
        }
        .padding(.horizontal, 2)
    }

    private var shortVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            BrandSectionHeader(title)
                .padding(.leading, 2)
            BrandCard(content: content)
        }
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(BrandUI.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var engineEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("speech model")
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 12)

                Picker("", selection: $settings.engineVersion) {
                    ForEach(EngineVersion.allCases) { version in
                        Text(version.displayName)
                            .tag(version)
                    }
                }
                .labelsHidden()
                .brandMenuStyle()
            }

            enginePreparationStatus

            ForEach(installedModels.filter(\.isDownloaded)) { model in
                cardDivider

                HStack(spacing: 10) {
                    Text("parakeet \(model.version.rawValue)")
                    .foregroundStyle(BrandUI.textPrimary)

                    Text(model.onDiskSize)
                        .font(BrandUI.valueFont)
                        .foregroundStyle(BrandUI.textSecondary)

                    Spacer(minLength: 8)

                    if model.version == coordinator.activeEngineVersion {
                        Text("active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BrandUI.goldPale)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background {
                                Capsule()
                                    .fill(BrandUI.goldDeep.opacity(0.22))
                            }
                    }

                    Button("remove download") {
                        pendingModelRemoval = model.version
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                }
            }

            if let modelStoreMessage {
                Text(modelStoreMessage)
                    .font(.caption)
                    .foregroundStyle(BrandUI.gold)
            }

            if let message = coordinator.engineSwitchMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BrandUI.gold)
            }
        }
    }

    @ViewBuilder
    private var enginePreparationStatus: some View {
        switch coordinator.enginePreparationState {
        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressView(value: bounded(progress))
                    .progressViewStyle(.linear)
                    .tint(BrandUI.gold)
                    .frame(maxWidth: .infinity)

                Text("\(Int(bounded(progress) * 100))%")
                    .font(BrandUI.valueFont.monospacedDigit())
                    .foregroundStyle(BrandUI.gold)
                    .frame(width: 34, alignment: .trailing)

                Text("downloading")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }

        case .warmingUp:
            Text("warming up")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)

        case .failed:
            HStack(spacing: 8) {
                Text("download failed")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)

                Button("retry") {
                    coordinator.retryEnginePrewarm()
                }
                .buttonStyle(.link)
                .foregroundStyle(BrandUI.gold)
            }

        case .notStarted, .ready:
            EmptyView()
        }
    }

    private func bounded(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    private func refreshInstalledModels() {
        installedModels = modelStore.installedModels()
    }

    private func removeDownload(_ version: EngineVersion) {
        let decision = modelStore.removalDecision(for: version)
        Task { @MainActor in
            if decision.requiresRepreparation {
                await coordinator.prepareForActiveModelRemoval(version)
            }

            do {
                try modelStore.remove(version)
                modelStoreMessage = nil
            } catch {
                modelStoreMessage = "couldn’t remove download"
            }
            refreshInstalledModels()
        }
    }

    @ViewBuilder
    private func hotkeyRow(for mode: DictationMode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(mode.rawValue)
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 10)

                KeyChip(settings.hotkeyBinding(for: mode).displayName)

                Picker(
                    "",
                    selection: Binding(
                        get: { settings.hotkeyBinding(for: mode) },
                        set: { binding in
                            _ = coordinator.rebindHotkey(
                                mode,
                                to: binding
                            )
                        }
                    )
                ) {
                    ForEach(HotkeyBinding.supported) { binding in
                        Text(binding.displayName)
                            .tag(binding)
                            .disabled(
                                binding
                                    == settings.hotkeyBinding(for: mode.other)
                            )
                    }
                }
                .labelsHidden()
                .brandMenuStyle()
                .frame(width: 146)
            }

            Text(
                settings.hotkeyBinding(for: mode.other).displayName
                    + " is already used by the "
                    + mode.other.rawValue
                    + " key"
            )
            .font(.caption)
            .foregroundStyle(BrandUI.gold.opacity(0.76))
        }
    }

    private var commandModeEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("agent cli")
                    .font(BrandUI.bodyFont.weight(.medium))
                    .frame(width: 86, alignment: .leading)

                AgentCLIEditor(
                    settings: settings,
                    detectedAgents: detectedAgents
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cardDivider

            HStack(spacing: 14) {
                Text("terminal")
                    .font(BrandUI.bodyFont.weight(.medium))
                    .frame(width: 86, alignment: .leading)

                Picker(
                    "",
                    selection: $settings.terminalBundleID
                ) {
                    ForEach(installedTerminals) { terminal in
                        Text(terminal.displayName)
                            .tag(terminal.bundleIdentifier)
                    }
                }
                .labelsHidden()
                .brandMenuStyle()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func selectAvailableTerminalIfNeeded() {
        guard !installedTerminals.contains(where: {
            $0.bundleIdentifier == settings.terminalBundleID
        }), let fallback = installedTerminals.first else {
            return
        }
        settings.terminalBundleID = fallback.bundleIdentifier
    }

}

private struct CustomActionEditor: View {
    @ObservedObject var store: CustomActionStore

    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionHeader

            if store.actions.isEmpty {
                Text("add a phrase to run something.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ForEach(store.actions) { action in
                    CustomActionRow(
                        action: action,
                        store: store,
                        onRemove: {
                            store.remove(action)
                        }
                    )

                    if action.id != store.actions.last?.id {
                        Rectangle()
                            .fill(BrandUI.hairline)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }

            HStack(spacing: 9) {
                Button(action: addAction) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
                .help("add action")

                Spacer()

                Button("import", action: importActions)
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)

                Button("export", action: exportActions)
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)

                Button("open actions file", action: revealActionsFile)
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BrandUI.gold)
            }
        }
    }

    private var actionHeader: some View {
        HStack(spacing: 8) {
            Text("trigger")
                .frame(width: 106, alignment: .leading)
            Text("type")
                .frame(width: 76, alignment: .leading)
            Text("payload")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("allow")
                .frame(width: 38, alignment: .center)
            Color.clear
                .frame(width: 14)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(BrandUI.textSecondary)
        .padding(.horizontal, 2)
    }

    private func addAction() {
        var suffix = 1
        var trigger = "new action"
        let normalizedKeys = Set(store.actions.compactMap {
            try? CustomActionMatcher.triggerPattern(
                for: $0.trigger
            ).normalizedKey
        })

        while normalizedKeys.contains(
            CustomActionMatcher.normalize(trigger)
        ) {
            suffix += 1
            trigger = "new action \(suffix)"
        }

        do {
            _ = try store.add(
                trigger: trigger,
                type: .open,
                payload: "finder"
            )
            message = nil
        } catch {
            message = error.localizedDescription.lowercased()
        }
    }

    private func importActions() {
        let panel = NSOpenPanel()
        panel.title = "import actions"
        panel.prompt = "import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK,
              let sourceURL = panel.url else {
            return
        }

        do {
            try store.importJSON(from: sourceURL)
            message = nil
        } catch let error as CustomActionValidationError {
            message = error.localizedDescription
        } catch {
            message = "couldn't import actions"
        }
    }

    private func exportActions() {
        let panel = NSSavePanel()
        panel.title = "export actions"
        panel.prompt = "export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "actions.json"

        guard panel.runModal() == .OK,
              let destinationURL = panel.url else {
            return
        }

        do {
            try store.exportJSON(to: destinationURL)
            message = nil
        } catch {
            message = "couldn't export actions"
        }
    }

    private func revealActionsFile() {
        do {
            try store.ensureFileExists()
            NSWorkspace.shared.activateFileViewerSelecting(
                [store.fileURL]
            )
            message = nil
        } catch {
            message = "couldn't open actions file"
        }
    }
}

private struct CustomActionRow: View {
    private enum Field: Hashable {
        case trigger
        case payload
    }

    let action: CustomAction
    @ObservedObject var store: CustomActionStore
    let onRemove: () -> Void

    @State private var draft: CustomAction
    @FocusState private var focusedField: Field?

    init(
        action: CustomAction,
        store: CustomActionStore,
        onRemove: @escaping () -> Void
    ) {
        self.action = action
        self.store = store
        self.onRemove = onRemove
        _draft = State(initialValue: action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                field(
                    prompt: "phrase",
                    text: $draft.trigger
                )
                .frame(width: 106)
                .focused($focusedField, equals: .trigger)

                Picker("", selection: $draft.type) {
                    ForEach(ActionType.allCases) { type in
                        Text(type.rawValue)
                            .tag(type)
                    }
                }
                .labelsHidden()
                .brandMenuStyle()
                .frame(width: 76)
                .onChange(of: draft.type) {
                    commitIfValid()
                }

                field(
                    prompt: "value",
                    text: $draft.payload
                )
                .frame(maxWidth: .infinity)
                .focused($focusedField, equals: .payload)

                Group {
                    if draft.type == .shell || draft.type == .ask {
                        Toggle("", isOn: $draft.alwaysAllow)
                            .labelsHidden()
                            .brandToggleStyle()
                            .scaleEffect(0.78)
                            .onChange(of: draft.alwaysAllow) {
                                commitIfValid()
                            }
                            .help("always allow")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 38)

                Button(action: onRemove) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.textSecondary)
                .frame(width: 14)
                .help("remove action")
            }

            if let validationError {
                Text(validationError.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(BrandUI.gold)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 3)
        .onSubmit(commitIfValid)
        .onChange(of: focusedField) { oldField, newField in
            if oldField != nil, newField == nil {
                commitIfValid()
            }
        }
        .onChange(of: action) { _, newAction in
            if focusedField == nil {
                draft = newAction
            }
        }
    }

    private var validationError: CustomActionValidationError? {
        store.validationError(for: draft)
    }

    private func field(
        prompt: String,
        text: Binding<String>
    ) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .labelsHidden()
            .font(BrandUI.valueFont)
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .frame(height: 27)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(BrandUI.windowBg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(BrandUI.hairline, lineWidth: 1)
            }
    }

    private func commitIfValid() {
        guard validationError == nil, draft != action else {
            return
        }
        try? store.update(draft)
    }
}

private struct DictionaryEditor: View {
    @ObservedObject var store: DictionaryStore

    @State private var selection: Set<UUID> = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Table(store.entries, selection: $selection) {
                TableColumn("wrong") { entry in
                    DictionaryCellEditor(
                        value: entry.wrong,
                        prompt: "wrong"
                    ) {
                        store.updateWrong(id: entry.id, wrong: $0)
                    }
                }

                TableColumn("right") { entry in
                    DictionaryCellEditor(
                        value: entry.right,
                        prompt: "right"
                    ) {
                        store.updateRight(id: entry.id, right: $0)
                    }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(BrandUI.windowBg.opacity(0.55))
            .frame(minWidth: 420, minHeight: 190)
            .overlay {
                if store.entries.isEmpty {
                    Text("teach andrew a word.")
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    let entry = store.add(wrong: "", right: "")
                    selection = [entry.id]
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
                .help("add row")

                Button {
                    for id in selection {
                        store.remove(id: id)
                    }
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.textSecondary)
                .disabled(selection.isEmpty)
                .help("delete selected row")

                Spacer()

                Button("import", action: importDictionary)
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
                Button("export", action: exportDictionary)
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BrandUI.gold)
            }
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.title = "import dictionary"
        panel.prompt = "import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK,
              let sourceURL = panel.url else {
            return
        }

        do {
            try store.importJSON(from: sourceURL)
            selection.removeAll()
            message = nil
        } catch {
            message = "couldn’t import dictionary"
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.title = "export dictionary"
        panel.prompt = "export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dictionary.json"

        guard panel.runModal() == .OK,
              let destinationURL = panel.url else {
            return
        }

        do {
            try store.exportJSON(to: destinationURL)
            message = nil
        } catch {
            message = "couldn’t export dictionary"
        }
    }
}

private struct DictionaryCellEditor: View {
    let value: String
    let prompt: String
    let onCommit: (String) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        value: String,
        prompt: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.value = value
        self.prompt = prompt
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField("", text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .font(BrandUI.bodyFont)
            .textFieldStyle(.plain)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(BrandUI.hairline)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { wasFocused, isFocused in
                if wasFocused, !isFocused {
                    commit()
                }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused {
                    draft = newValue
                }
            }
    }

    private func commit() {
        guard draft != value else {
            return
        }
        onCommit(draft)
    }
}

private struct TerminalOption: Identifiable {
    let bundleIdentifier: String
    let displayName: String

    var id: String {
        bundleIdentifier
    }
}

@MainActor
private enum TerminalDetector {
    static func detectInstalled(
        workspace: NSWorkspace = .shared
    ) -> [TerminalOption] {
        [
            TerminalOption(
                bundleIdentifier: "com.apple.Terminal",
                displayName: "terminal"
            ),
            TerminalOption(
                bundleIdentifier: "com.googlecode.iterm2",
                displayName: "iterm2"
            ),
            TerminalOption(
                bundleIdentifier: "com.mitchellh.ghostty",
                displayName: "ghostty"
            ),
            TerminalOption(
                bundleIdentifier: "dev.warp.Warp-Stable",
                displayName: "warp"
            ),
        ].filter {
            workspace.urlForApplication(
                withBundleIdentifier: $0.bundleIdentifier
            ) != nil
        }
    }
}

@MainActor
private final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            message = nil
        case .requiresApproval:
            isEnabled = true
            message = "approval is required in system settings"
        case .notFound:
            isEnabled = false
            message = "launch at login is unavailable"
        case .notRegistered:
            isEnabled = false
            message = nil
        @unknown default:
            isEnabled = false
            message = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            message = "couldn’t update launch at login"
        }
    }
}
