import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation
    case meetings
    case dictionary
    case history
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "dictation"
        case .dictionary: "dictionary"
        case .history: "history"
        case .meetings: "meetings"
        case .general: "general"
        }
    }
}

/// history holds two different nouns — your own speech, and other people's
/// words — and ADR 0022 keeps them apart on purpose. one switch, not two
/// panes: it is the same question asked of two piles.
private enum HistorySegment: String, CaseIterable, Identifiable {
    case dictations
    case meetings

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var dictionaryStore: DictionaryStore
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var archive = ArchiveSettingsModel()
    @StateObject private var browser = ArchiveBrowserViewModel()
    @StateObject private var meetings: MeetingsListModel

    private let modelStore: ModelStore

    @State private var selectedTab: SettingsTab = .dictation
    @State private var historySegment: HistorySegment = .dictations
    @State private var installedModels: [InstalledModel] = []
    @State private var pendingModelRemoval: EngineVersion?
    @State private var modelStoreMessage: String?
    @State private var showsRemoval = false
    @State private var timings: TimelineSummary?

    /// `meetingsLoader` is left open on purpose: this pane knows how to draw
    /// the meetings folder, not where it is or how to read it.
    init(
        coordinator: DictationCoordinator,
        meetingsLoader: @escaping () -> [MeetingSummary] = { [] }
    ) {
        let settings = coordinator.settings

        _coordinator = ObservedObject(wrappedValue: coordinator)
        _meetings = StateObject(
            wrappedValue: MeetingsListModel(load: meetingsLoader)
        )
        _settings = ObservedObject(wrappedValue: settings)
        _dictionaryStore = ObservedObject(
            wrappedValue: coordinator.dictionaryStore
        )
        modelStore = ModelStore(
            activeVersion: { coordinator.activeEngineVersion }
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(
                "dictation",
                systemImage: "waveform",
                value: SettingsTab.dictation
            ) {
                dictationTab
            }
            Tab(
                "meetings",
                systemImage: "person.2.wave.2",
                value: SettingsTab.meetings
            ) {
                meetingsTab
            }
            Tab(
                "dictionary",
                systemImage: "character.book.closed",
                value: SettingsTab.dictionary
            ) {
                dictionaryTab
            }
            Tab(
                "history",
                systemImage: "clock.arrow.circlepath",
                value: SettingsTab.history
            ) {
                historyTab
            }
            Tab(
                "general",
                systemImage: "gearshape",
                value: SettingsTab.general
            ) {
                generalTab
            }
        }
        .frame(width: 800)
        .brandGlassWindow()
        .foregroundStyle(BrandUI.textPrimary)
        .font(BrandUI.bodyFont)
        .brandTinted()
        .controlSize(.small)
        .preferredColorScheme(.dark)
        .onAppear {
            // an LSUIElement app opening its settings scene may not be the
            // active app, which would leave the window behind everything.
            NSApp.activate(ignoringOtherApps: true)
            loginItem.refresh()
            refreshInstalledModels()
            // read from disk on open: counts have to be the number of things
            // that exist, not a number this pane remembered.
            archive.refresh()
            browser.reload()
            meetings.reload()
            timings = coordinator.timingsSummary()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .history {
                browser.reload()
                meetings.reload()
            }
            if tab == .general {
                timings = coordinator.timingsSummary()
            }
        }
        .onChange(of: historySegment) { _, segment in
            if segment == .meetings {
                meetings.reload()
            }
        }
        .onChange(of: coordinator.enginePreparationState) { _, state in
            if state == .ready || state == .failed {
                refreshInstalledModels()
            }
        }
        .sheet(isPresented: $showsRemoval) {
            RemovalView()
                .frame(width: 480, height: 500)
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

    // MARK: - chrome

    private var setupIssues: [SetupIssue] {
        SetupHealth.issues(
            permissions: coordinator.permissions,
            speechModelFailed:
                coordinator.enginePreparationState == .failed
        )
    }

    /// names what's missing, then hands back to onboarding — the one place
    /// that knows how to ask macOS for any of it.
    private var setupBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(setupIssues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(BrandUI.bodyFont.weight(.medium))
                        .foregroundStyle(BrandUI.attention)

                    Text(issue.detail)
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }

            Button("finish setup") {
                coordinator.runOnboardingAgain()
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandUI.gold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(BrandUI.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: - dictation

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 13) {
            // only when something is actually wrong: three permanent green
            // ticks would teach you to stop reading it. it lives on the
            // pane you land on, because a broken permission outranks
            // whatever you came for.
            if !setupIssues.isEmpty {
                setupBanner
                rowDivider
            }

            hotkeyRow
            rowDivider
            DictationOptionRow(
                option: .preRoll,
                settings: settings
            )
            rowDivider
            DictationOptionRow(
                option: .soundFeedback,
                settings: settings
            )
            rowDivider
            PipelineView(coordinator: coordinator, settings: settings)
            rowDivider
            engineEditor
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    private var hotkeyRow: some View {
        HStack(spacing: 10) {
            Text("key")
                .font(BrandUI.bodyFont.weight(.medium))

            Spacer(minLength: 10)

            // the chip is the control — it and a picker beside it showed the
            // same value twice.
            Menu {
                ForEach(HotkeyBinding.supported) { binding in
                    Button(binding.displayName) {
                        _ = coordinator.rebindHotkey(to: binding)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    KeyChip(settings.dictationHotkey.displayName)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BrandUI.textSecondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("dictation key")
        }
    }

    private var engineEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("speech model")
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 12)

                Text("what turns your voice into words. on this mac, always.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }

            // the picker is the list (ADR 0039): the tradeoff is the
            // decision, so it goes on the control.
            ModelChooserView(
                selection: $settings.engineVersion,
                active: coordinator.activeEngineVersion,
                preparation: coordinator.enginePreparationState,
                installed: installedModels,
                onRetry: { coordinator.retryEnginePrewarm() }
            )

            // storage is one quiet line, not a button per row.
            HStack(spacing: 12) {
                Text("shared with other FluidAudio apps, downloaded once.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)

                Spacer(minLength: 8)

                Button("show in finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [AppIdentity.sharedModelDirectory]
                    )
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)

                if installedModels.contains(where: \.isDownloaded) {
                    Menu("remove a download…") {
                        ForEach(
                            installedModels.filter(\.isDownloaded)
                        ) { model in
                            Button(
                                "\(model.version.shortName) · "
                                    + model.onDiskSize
                            ) {
                                pendingModelRemoval = model.version
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                    .fixedSize()
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

    // MARK: - dictionary

    private var dictionaryTab: some View {
        DictionaryEditor(
            store: dictionaryStore,
            settings: settings,
            dictations: browser.items
        )
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 20)
    }

    // MARK: - history

    /// list first: the two things anyone comes here for are "fix a word
    /// in something i said" and "delete something i said". keeping-or-not
    /// is a footer, because it's set once and never looked at again.
    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $historySegment) {
                ForEach(HistorySegment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
            .accessibilityLabel("what history shows")

            switch historySegment {
            case .dictations:
                ArchiveBrowserView(
                    viewModel: browser,
                    fixAWord: { coordinator.openWordFixer(for: $0) }
                )
                .frame(height: 330)
            case .meetings:
                MeetingsBrowserView(viewModel: meetings)
                    .frame(height: 330)
            }

            rowDivider
                .padding(.horizontal, 24)

            switch historySegment {
            case .dictations: dictationsFooter
            case .meetings: meetingsFooter
            }
        }
        .padding(.top, 8)
    }

    private var dictationsFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle(
                    "keep new dictations",
                    isOn: $settings.keepDictations
                )
                .brandToggleStyle()
                .font(BrandUI.bodyFont)

                Spacer(minLength: 8)

                Text(
                    browser.items.count == 1
                        ? "1 kept"
                        : "\(browser.items.count) kept"
                )
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)

                Button("delete all") {
                    archive.deleteEverything()
                    browser.reload()
                }
                .disabled(browser.items.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            if let failure = archive.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(BrandUI.attention)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }
        }
    }

    /// no keep-or-not switch here: a meeting recording is kept until you
    /// delete it, and the folder it lives in is the whole feature.
    private var meetingsFooter: some View {
        HStack(spacing: 12) {
            Text(
                meetings.items.count == 1
                    ? "1 meeting"
                    : "\(meetings.items.count) meetings"
            )
            .font(.caption)
            .foregroundStyle(BrandUI.textSecondary)

            Spacer(minLength: 8)

            Button("show folder in finder") {
                showInFinder(
                    settings.meetingsFolder
                        .appendingPathComponent("meetings", isDirectory: true)
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - meetings

    private var meetingsTab: some View {
        VStack(alignment: .leading, spacing: 13) {
            meetingModelEditor
            rowDivider
            meetingsFolderRow
            rowDivider
            meetingHookRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    /// the same cards dictation uses — each job picks its own model, and the
    /// card states the consequence (ADR 0040).
    private var meetingModelEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("meeting model")
                    .font(BrandUI.bodyFont.weight(.medium))

                Spacer(minLength: 12)

                Text("what listens in meetings. on this mac, always.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }

            MeetingModelChooserView(
                selection: $settings.meetingModel,
                installed: coordinator.installedMeetingModels,
                downloading: coordinator.meetingModelDownloads
            )
        }
    }

    private var meetingsFolderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("save meetings in")
                    .font(BrandUI.bodyFont.weight(.medium))

                Text(tildePath(settings.meetingsFolder))
                    .font(BrandUI.machineFont(size: 12))
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button("change…", action: chooseMeetingsFolder)

            Button("show in finder") {
                showInFinder(settings.meetingsFolder)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(BrandUI.textSecondary)
        }
    }

    private var meetingHookRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("after a meeting is saved, run")
                        .font(BrandUI.bodyFont.weight(.medium))

                    Text(settings.meetingHook.map(tildePath) ?? "nothing")
                        .font(BrandUI.machineFont(size: 12))
                        .foregroundStyle(BrandUI.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                Button("choose…", action: chooseMeetingHook)

                if settings.meetingHook != nil {
                    Button("clear") {
                        settings.meetingHook = nil
                        settings.meetingHookLastRunAt = nil
                        settings.meetingHookLastRunLabel = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                }
            }

            // a hook that failed silently is a hook nobody can fix, so the
            // last run stays on the row until the next one replaces it.
            if let ranAt = settings.meetingHookLastRunAt {
                HStack(spacing: 6) {
                    Text(
                        "last run: "
                            + ranAt.formatted(
                                .relative(presentation: .named)
                            )
                            + " · "
                            + (settings.meetingHookLastRunLabel ?? "ok")
                    )
                    .font(.caption)
                    .foregroundStyle(
                        hookFailed ? BrandUI.attention : BrandUI.textSecondary
                    )

                    if hookFailed {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(BrandUI.textSecondary)
                            .accessibilityHidden(true)

                        Button("open log", action: openHooksLog)
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(BrandUI.gold)
                    }
                }
            }

            Text(
                "gets the transcript path as $1 and the same details as "
                    + "json on stdin."
            )
            .font(.caption)
            .foregroundStyle(BrandUI.textSecondary)
        }
    }

    private var hookFailed: Bool {
        guard let label = settings.meetingHookLastRunLabel else {
            return false
        }
        return label != "ok"
    }

    private func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.title = "save meetings in"
        panel.prompt = "choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.meetingsFolder

        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }
        settings.meetingsFolder = folder
    }

    /// any file: the hook is whatever you can run — a shell script, a
    /// binary, a shortcut wrapper. filtering by type would only be a guess
    /// about someone else's toolchain.
    private func chooseMeetingHook() {
        let panel = NSOpenPanel()
        panel.title = "after a meeting is saved, run"
        panel.prompt = "choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = settings.meetingHook?.deletingLastPathComponent()

        guard panel.runModal() == .OK, let hook = panel.url else {
            return
        }
        settings.meetingHook = hook
        settings.meetingHookLastRunAt = nil
        settings.meetingHookLastRunLabel = nil
    }

    /// everything the hook printed, in one file beside everything else this
    /// app keeps.
    private func openHooksLog() {
        let log = AppIdentity.supportDirectory
            .appendingPathComponent("hooks.log", isDirectory: false)
        if !NSWorkspace.shared.open(log) {
            showInFinder(log)
        }
    }

    private func tildePath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath
    }

    /// revealing something that isn't there yet opens nothing at all, which
    /// is a button that looks broken. walk up to the nearest folder that
    /// does exist — the meetings folder is made on the first recording.
    private func showInFinder(_ url: URL) {
        var target = url
        while target.pathComponents.count > 1,
              !FileManager.default.fileExists(
                  atPath: target.path(percentEncoded: false)
              ) {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - general

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 13) {
            SettingsToggleRow(
                "launch at login",
                explanation: "starts Andrew Dictate when you sign in.",
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            )

            if let message = loginItem.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            }

            rowDivider

            numbersDashboard

            // leaving lives here, under its own name — it sat inside the
            // history pane as "remove everything…" and nobody could find it.
            if Capabilities.current.canUninstall {
                rowDivider

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("leaving?")
                            .font(BrandUI.bodyFont.weight(.medium))
                        Text("removes what's on this mac, piece by piece.")
                            .font(BrandUI.bodyFont)
                            .foregroundStyle(BrandUI.textSecondary)
                    }

                    Spacer(minLength: 8)

                    Button("remove Andrew Dictate…") {
                        showsRemoval = true
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    /// the numbers, visible. "copy timings" used to be a button whose output
    /// you could only see by pasting it somewhere; the claim it carries now
    /// has a face, and the copy button ships the full report underneath it.
    private var numbersDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandSectionHeader("the numbers")

            HStack(alignment: .top, spacing: 36) {
                statTile(
                    "words typed",
                    settings.totalWordsDictated.formatted(
                        .number.grouping(.automatic)
                    )
                )
                statTile(
                    "typical paste",
                    milliseconds(timings?.keyUpToCompletion?.p50)
                )
                statTile(
                    "worst 1-in-20",
                    milliseconds(timings?.keyUpToCompletion?.p95)
                )
            }

            HStack(spacing: 10) {
                Text(sampleLine)
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)

                Spacer(minLength: 8)

                if Capabilities.current.canCopyTimings {
                    Button("copy the full report") {
                        coordinator.copyTimings()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(BrandUI.gold)
                }
            }
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(BrandUI.machineFont(size: 22, bold: true))
                .foregroundStyle(BrandUI.textPrimary)

            Text(label)
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var sampleLine: String {
        guard let timings, timings.sampleSize > 0 else {
            return "no verified pastes measured yet — dictate something."
        }
        return timings.sampleSize == 1
            ? "measured over 1 verified paste on this mac."
            : "measured over \(timings.sampleSize) verified pastes "
                + "on this mac."
    }

    private func milliseconds(_ duration: Duration?) -> String {
        guard let duration else {
            return "—"
        }
        return "\(Int(duration.inMilliseconds.rounded())) ms"
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
}

/// a decoded import, held between the panel closing and the answer to "add
/// or replace?" — not one byte is written while this is set.
private struct PendingImport {
    let entries: [DictionaryEntry]
    let existingCount: Int
}

private struct DictionaryEditor: View {
    @ObservedObject var store: DictionaryStore
    @ObservedObject var settings: AppSettings
    /// handed in, never re-read: the history pane already holds them.
    let dictations: [Dictation]

    @State private var selection: Set<UUID> = []
    @State private var message: String?
    @State private var pendingImport: PendingImport?
    @State private var suggestions: [RecurringMishearings.Candidate] = []
    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // nothing when there is nothing: an empty section above the
            // table would be a row of chrome asking about no words.
            if !suggestions.isEmpty {
                suggestionSection
            }

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
        .alert(
            "add these to your dictionary, or replace it?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { presented in
                    if !presented {
                        pendingImport = nil
                    }
                }
            ),
            presenting: pendingImport
        ) { pending in
            Button("add to mine") { addImport(pending) }
            Button("replace", role: .destructive) {
                replaceWithImport(pending)
            }
            Button("cancel", role: .cancel) {}
        } message: { pending in
            Text(
                """
                the file has \(words(pending.entries.count)). you’ve taught \
                andrew \(words(pending.existingCount)).
                """
            )
        }
        // on appear only. this reads every kept dictation, and it is not a
        // thing to do on a keystroke.
        .onAppear(perform: refreshSuggestions)
    }

    /// It asks rather than asserts: the app genuinely cannot tell "swiggy"
    /// (right) from "kunur" (wrong), and nothing here is added for you.
    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            BrandSectionHeader("did it get these right?")

            Text("words you said more than once that andrew doesn’t know. teach it the ones it got wrong.")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(suggestions) { candidate in
                suggestionRow(candidate)
            }
        }
        .padding(.bottom, 6)
    }

    private func suggestionRow(
        _ candidate: RecurringMishearings.Candidate
    ) -> some View {
        HStack(spacing: 8) {
            Text("heard “\(candidate.heard)”")
                .font(BrandUI.machineFont(size: 12))
                .foregroundStyle(BrandUI.goldPale)

            Text("· \(candidate.count) times")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)

            TextField(
                "what you meant",
                text: Binding(
                    get: { draft(for: candidate) },
                    set: { drafts[candidate.heard] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .onSubmit { teach(candidate) }

            Button("save") { teach(candidate) }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
                .disabled(
                    draft(for: candidate)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )

            Button("not a mistake") { dismiss(candidate) }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.textSecondary)

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    /// a word you spelled out loud near it is the answer you already gave —
    /// the field opens with it.
    private func draft(
        for candidate: RecurringMishearings.Candidate
    ) -> String {
        drafts[candidate.heard] ?? candidate.spelledOut ?? ""
    }

    private func teach(_ candidate: RecurringMishearings.Candidate) {
        let right = draft(for: candidate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty,
              store.add(wrong: candidate.heard, right: right) else {
            return
        }
        drafts[candidate.heard] = nil
        suggestions.removeAll { $0.heard == candidate.heard }
    }

    private func dismiss(_ candidate: RecurringMishearings.Candidate) {
        settings.dismissSuggestion(candidate.heard)
        suggestions.removeAll { $0.heard == candidate.heard }
    }

    private func refreshSuggestions() {
        suggestions = RecurringMishearings.scan(
            dictations,
            dictionary: store.entries,
            dismissed: settings.dismissedSuggestions,
            isSuspect: { RecurringMishearings.isSuspect($0) },
            now: Date()
        )
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

        // a second import must not wear the first one’s receipt.
        message = nil

        guard let imported = store.decodeEntries(from: sourceURL) else {
            // the store publishes the specific reason itself; this is only
            // the fallback for a failure it somehow didn’t record.
            message = store.lastFailure == nil
                ? "couldn’t import dictionary"
                : nil
            return
        }

        guard !store.entries.isEmpty else {
            // nothing to lose, so nothing to ask.
            guard store.replace(with: imported) else {
                return
            }
            selection.removeAll()
            message = "added \(words(imported.count))."
            return
        }

        // nothing is written until the alert is answered: "import" is the one
        // word on this row that does not sound like "delete everything".
        pendingImport = PendingImport(
            entries: imported,
            existingCount: store.entries.count
        )
    }

    private func addImport(_ pending: PendingImport) {
        guard let result = store.merge(pending.entries) else {
            return
        }
        selection.removeAll()
        message = "added \(words(result.added))."
    }

    private func replaceWithImport(_ pending: PendingImport) {
        let lost = pending.existingCount
        guard store.replace(with: pending.entries) else {
            return
        }
        selection.removeAll()
        message = "replaced \(words(lost)) with \(pending.entries.count)."
    }

    /// "added 1 word.", not "added 1 words." — the deadpan voice stops being
    /// one the moment it reads like a log line.
    private func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
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
