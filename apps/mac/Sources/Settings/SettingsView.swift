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
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var archive = ArchiveSettingsModel()

    private let modelStore: ModelStore

    @State private var installedModels: [InstalledModel] = []
    @State private var pendingModelRemoval: EngineVersion?
    @State private var modelStoreMessage: String?
    @State private var isCleanupAvailable: Bool

    init(coordinator: DictationCoordinator) {
        let settings = coordinator.settings

        _coordinator = ObservedObject(wrappedValue: coordinator)
        _settings = ObservedObject(wrappedValue: settings)
        _dictionaryStore = ObservedObject(
            wrappedValue: coordinator.dictionaryStore
        )
        modelStore = ModelStore(
            activeVersion: { coordinator.activeEngineVersion }
        )
        _isCleanupAvailable = State(
            initialValue: coordinator.isCleanupAvailable
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identityStrip

                // only when something is actually wrong: three permanent
                // green ticks would teach you to stop reading this card.
                if !setupIssues.isEmpty {
                    settingsSection("setup") {
                        setupHealthCard
                    }
                }

                settingsSection("dictation key") {
                    hotkeyRow
                }

                settingsSection("dictation") {
                    VStack(alignment: .leading, spacing: 13) {
                        DictationOptionRow(
                            option: .preRoll,
                            settings: settings
                        )
                        cardDivider
                        DictationOptionRow(
                            option: .soundFeedback,
                            settings: settings
                        )
                        cardDivider
                        aiCleanupEditor
                        cardDivider
                        cleanupLabControls
                    }
                }

                settingsSection("speech model") {
                    engineEditor
                }

                settingsSection("dictionary") {
                    DictionaryEditor(store: dictionaryStore)
                }

                settingsSection("what it keeps") {
                    SettingsToggleRow(
                        "keep what you dictate",
                        explanation:
                            "on this mac, until you delete it.",
                        isOn: $settings.keepDictations
                    )

                    HStack(spacing: 10) {
                        Text(
                            archive.count == 1
                                ? "1 dictation kept"
                                : "\(archive.count) dictations kept"
                        )
                        .font(BrandUI.bodyFont)
                        .foregroundStyle(BrandUI.textSecondary)

                        Spacer(minLength: 8)

                        Button("delete all") { archive.deleteEverything() }
                            .disabled(archive.count == 0)
                    }
                    .padding(.top, 8)

                    if let failure = archive.failure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(BrandUI.attention)
                            .padding(.top, 6)
                    }
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
        // read from disk on open: the count has to be the number of things
        // that exist, not a number this pane remembered.
        .onAppear { archive.refresh() }
        .font(BrandUI.bodyFont)
        .brandTinted()
        .controlSize(.small)
        .frame(minWidth: 540, minHeight: 560)
        .preferredColorScheme(.dark)
        .onAppear {
            loginItem.refresh()
            refreshInstalledModels()
            isCleanupAvailable = coordinator.isCleanupAvailable
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

    private var setupIssues: [SetupIssue] {
        SetupHealth.issues(
            permissions: coordinator.permissions,
            speechModelFailed:
                coordinator.enginePreparationState == .failed
        )
    }

    /// names what's missing, then hands back to onboarding — the one place
    /// that knows how to ask macOS for any of it.
    private var setupHealthCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(setupIssues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(BrandUI.bodyFont.weight(.medium))
                        .foregroundStyle(BrandUI.textPrimary)

                    Text(issue.detail)
                        .font(BrandUI.bodyFont)
                        .foregroundStyle(BrandUI.textSecondary)
                }
                .accessibilityElement(children: .combine)

                if issue.id != setupIssues.last?.id {
                    cardDivider
                }
            }

            Button("finish setup") {
                coordinator.runOnboardingAgain()
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandUI.gold)
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

    /// shown on every mac, disabled where the os can’t run it: hiding
    /// the row entirely taught older machines the feature doesn’t exist.
    private var aiCleanupEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("ai cleanup")
                    .font(BrandUI.bodyFont.weight(.medium))
                    .opacity(isCleanupAvailable ? 1 : 0.55)

                Spacer(minLength: 12)

                Picker("", selection: $settings.cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.rawValue)
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                .accessibilityLabel("ai cleanup")
            }

            Text(
                isCleanupAvailable
                    ? settings.cleanupMode.explanation
                    : "needs macOS 26 — apple’s on-device model"
            )
            .font(.caption)
            .foregroundStyle(BrandUI.textSecondary)
            .lineLimit(1)
        }
        .disabled(!isCleanupAvailable)
    }

    private var cleanupLabControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("cleanup lab")
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 12)

                Button("view the pipeline") {
                    coordinator.openPipelinePlayground()
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)

                Button("view cleanup lab") {
                    coordinator.openCleanupLab()
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)

                Button("clear lab data") {
                    coordinator.clearCleanupLabData()
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.textSecondary)
            }

            Text("compares recent raw/cleaned pairs newest first.")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
                .lineLimit(1)
        }
    }

    private var engineEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // the section header already says "speech model" — this row
                // picks which one, so it says that instead of repeating it.
                Text("version")
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
                .accessibilityLabel("speech model version")
            }

            enginePreparationStatus

            // The models are not this app's private copy — FluidAudio keeps one
            // shared cache, so a second app built on it (and this app's own
            // development build) reuses the same 443 MB rather than fetching it
            // again. That was already true and completely invisible.
            cardDivider

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("models are shared, and downloaded once")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)

                Spacer(minLength: 8)

                Button("show in finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [AppIdentity.sharedModelDirectory]
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }

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
                    // every row's button read "remove download" and
                    // nothing else, so voiceover users heard the same
                    // button repeated once per installed model.
                    .accessibilityLabel(
                        "remove parakeet \(model.version.rawValue) download"
                    )
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

    /// the filesystem goes first. unloading the engine up front meant a
    /// failed delete left you with nothing loaded, the model still on
    /// disk, and no idea why — so a failure here must cost nothing.
    private func removeDownload(_ version: EngineVersion) {
        let decision: ModelRemovalDecision
        do {
            decision = try modelStore.remove(version)
            modelStoreMessage = nil
        } catch {
            modelStoreMessage = error.localizedDescription
            refreshInstalledModels()
            return
        }

        refreshInstalledModels()

        guard decision.requiresRepreparation else {
            return
        }

        Task { @MainActor in
            await coordinator.prepareForActiveModelRemoval(version)
        }
    }

    private var hotkeyRow: some View {
        HStack(spacing: 10) {
            Text("dictation")
                .font(BrandUI.bodyFont.weight(.medium))

            Spacer(minLength: 10)

            KeyChip(settings.dictationHotkey.displayName)

            Picker(
                "",
                selection: Binding(
                    get: { settings.dictationHotkey },
                    set: { binding in
                        _ = coordinator.rebindHotkey(to: binding)
                    }
                )
            ) {
                ForEach(HotkeyBinding.supported) { binding in
                    Text(binding.displayName)
                        .tag(binding)
                }
            }
            .labelsHidden()
            .brandMenuStyle()
            .accessibilityLabel("dictation key")
            .frame(width: 146)
        }
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
                    // an unreadable file is not an empty dictionary, and
                    // must never be invited to look like one.
                    Text(store.lastFailure ?? "teach andrew a word.")
                        .font(.caption)
                        .foregroundStyle(
                            store.lastFailure == nil
                                ? BrandUI.textSecondary
                                : BrandUI.gold
                        )
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }
            }

            HStack(spacing: 8) {
                Button {
                    let entry = DictionaryEntry(wrong: "", right: "")
                    if store.add(entry) {
                        selection = [entry.id]
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
                .help("add row")
                .accessibilityLabel("add dictionary entry")

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
                .accessibilityLabel("remove selected dictionary entries")
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

            // a dictionary that failed to load, import or save used to
            // look exactly like an empty one. the store says which.
            if let failure = store.lastFailure {
                Text(failure)
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

        guard store.importJSON(from: sourceURL) else {
            // the store publishes the specific reason itself; this is only
            // the fallback for a failure it somehow didn’t record.
            message = store.lastFailure == nil
                ? "couldn’t import dictionary"
                : nil
            return
        }

        selection.removeAll()
        message = nil
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

        guard store.exportJSON(to: destinationURL) else {
            message = store.lastFailure == nil
                ? "couldn’t export dictionary"
                : nil
            return
        }

        message = nil
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
