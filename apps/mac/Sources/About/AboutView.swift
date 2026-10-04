import AppKit
import Combine
import SwiftUI

/// the about window is a stamp, not a page: apple's own panel is 284×159
/// with the content sitting directly on the window — no inner card, no
/// visible title bar. same recipe here, painted in the brand.
/// (docs/research/about-windows.md)
@MainActor
final class AboutWindowController: NSWindowController {
    init(
        bundle: Bundle = .main,
        settings: AppSettings = .shared
    ) {
        let rootView = AboutView(bundle: bundle, settings: settings)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "about"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let size = NSSize(width: 300, height: 344)
        window.setContentSize(size)
        window.minSize = size
        window.maxSize = size
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = BrandUI.nsColor(BrandUI.windowBgRGB)
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

struct AboutView: View {
    enum UpdateStatus: Equatable {
        case idle
        case checking
        case upToDate
        case newer(String, URL)
        /// the bundle in /Applications is already the new one — brew swapped
        /// it, and this process is the copy that was running at the time.
        case alreadyInstalled(String)
        case unreachable
    }

    @ObservedObject private var settings: AppSettings
    @State private var showsRecord = false
    @State private var versionCopied = false
    @State private var upgradeCopied = false
    @State private var updateStatus: UpdateStatus = .idle
    private let version: String
    private let build: String
    /// brew put it there, brew replaces it. a dmg user handed a `brew upgrade`
    /// line would paste an error into their terminal, so they get sent to the
    /// page the dmg is on instead.
    private let installedByHomebrew: Bool

    init(
        bundle: Bundle = .main,
        settings: AppSettings = .shared
    ) {
        _settings = ObservedObject(wrappedValue: settings)

        let shortVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        version = shortVersion ?? "development"
        self.build = build ?? "development"
        installedByHomebrew = UpdateOffer.Install.detect() == .homebrew
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    showsRecord.toggle()
                }
            } label: {
                Image("Badge")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("andrew")

            Text("Andrew Dictate")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BrandUI.textPrimary)
                .padding(.top, 10)

            taglineOrRecord
                .padding(.top, 4)

            Button {
                copyVersion()
            } label: {
                Text(
                    versionCopied
                        ? "copied"
                        : "version \(version) · build \(build)"
                )
                .font(BrandUI.machineFont(size: 11))
                .foregroundStyle(BrandUI.textSecondary)
            }
            .buttonStyle(.plain)
            .help("click to copy")
            .padding(.top, 8)

            updatesLine
                .padding(.top, 7)

            Spacer(minLength: 12)

            // six names no longer fit one line in 268 pt, so it wraps, and
            // wrapped text leans left unless told otherwise.
            Text(creditsMarkdown)
                .font(.system(size: 10.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(BrandUI.textSecondary)
                .tint(BrandUI.gold.opacity(0.85))
                .help(Self.licenceTooltip)

            // a name in a hand font is a signature (jass.gg's role
            // system) — the one place the hand font is allowed.
            Text(signatureMarkdown)
                .font(BrandUI.handFont(size: 15))
                .foregroundStyle(BrandUI.textSecondary)
                .tint(BrandUI.gold)
                .padding(.top, 5)
        }
        .padding(.top, 30)
        .padding(.bottom, 18)
        .padding(.horizontal, 16)
        .frame(width: 300, height: 344)
        .brandGlassWindow()
        .preferredColorScheme(.dark)
        // brew can swap the bundle while this window sits open, so the line
        // rechecks the disk when the window appears and whenever the app is
        // brought forward. no network in either path.
        .task {
            noteAnyUpgradeOnDisk()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            noteAnyUpgradeOnDisk()
        }
    }

    /// one slot, two lines. the tagline is the screen; the lifetime word
    /// count is the reward for poking andrew.
    @ViewBuilder
    private var taglineOrRecord: some View {
        ZStack {
            if showsRecord {
                Text(lifetimeWordsText)
                    .foregroundStyle(BrandUI.goldPale)
                    .transition(.opacity)
            } else {
                Text("escape the keyboard.")
                    .foregroundStyle(BrandUI.gold)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var lifetimeWordsText: String {
        let count = settings.totalWordsDictated.formatted(
            .number.grouping(.automatic)
        )
        return "andrew has typed \(count) words. undefeated."
    }

    // single literals, not `+` chains: a chain of eight string literals
    // sent the release compiler into "unable to type-check in reasonable
    // time" and failed a tag build.
    private static let licenceTooltip = """
        FluidAudio: Apache-2.0 · parakeet weights: CC-BY-4.0 · \
        WhisperKit: MIT · whisper weights: MIT · \
        needle engine and whistle weights: Apache-2.0 · silero vad: MIT · \
        this app: MIT
        """

    private static let creditsSource = """
        built on [FluidAudio](https://github.com/FluidInference/FluidAudio), \
        [parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), \
        [WhisperKit](https://github.com/argmaxinc/WhisperKit), \
        [whisper](https://github.com/openai/whisper), \
        [whistle](https://huggingface.co/Cactus-Compute/whistle) \
        and [silero](https://github.com/snakers4/silero-vad)
        """

    private var creditsMarkdown: AttributedString {
        (try? AttributedString(markdown: Self.creditsSource))
            ?? AttributedString(
                "built on FluidAudio, parakeet, WhisperKit, whisper and silero"
            )
    }

    private var signatureMarkdown: AttributedString {
        let markdown =
            "[made by jass](https://jass.gg) · "
            + "[open source]"
            + "(https://github.com/jassuwu/andrew-dictate)"
        return (try? AttributedString(markdown: markdown))
            ?? AttributedString("made by jass")
    }

    /// asks github only when clicked, and a tag that doesn't parse never
    /// says "upgrade" — the quiet failure is "couldn't check", not a lie.
    @ViewBuilder
    private var updatesLine: some View {
        Group {
            switch updateStatus {
            case .idle:
                Button("check for updates") { checkForUpdates() }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)

            case .checking:
                Text("checking…")
                    .foregroundStyle(BrandUI.textSecondary)

            case .upToDate:
                Text("you're on the latest.")
                    .foregroundStyle(BrandUI.textSecondary)

            case let .newer(version, page):
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("\(version) is out —")
                            .foregroundStyle(BrandUI.gold)
                        Link("what changed", destination: page)
                            .foregroundStyle(BrandUI.textSecondary)
                    }
                    upgradeInstruction
                }

            case let .alreadyInstalled(version):
                Button {
                    AppRelaunch.now()
                } label: {
                    Text("\(version) is installed — restart andrew")
                        .foregroundStyle(BrandUI.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .help("quits andrew and opens it again")

            case .unreachable:
                Text("couldn't check — try again later.")
                    .foregroundStyle(BrandUI.textSecondary)
            }
        }
        .font(.system(size: 11))
    }

    /// the command, not a tab: every copy was installed with one brew line,
    /// so the update is one brew line — and it is the whole instruction,
    /// because brew carries the gatekeeper approval and the permission grants
    /// across. a github page would teach a dmg drag nobody here did.
    @ViewBuilder
    private var upgradeInstruction: some View {
        if installedByHomebrew {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    copyUpgradeCommand()
                } label: {
                    Text(
                        upgradeCopied
                            ? "copied — paste it in terminal"
                            : UpdateCheck.upgradeCommand
                    )
                    .font(BrandUI.machineFont(size: 9.5))
                    .foregroundStyle(BrandUI.goldPale)
                    .multilineTextAlignment(.leading)
                    // two lines are reserved either way, so the flash cannot
                    // shuffle everything under it.
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .help("click to copy")

                Text("no xattr step — your permissions stay.")
                    .font(.system(size: 10))
                    .foregroundStyle(BrandUI.textSecondary)
            }
        } else {
            Text("the new dmg is on the release page.")
                .font(.system(size: 10))
                .foregroundStyle(BrandUI.textSecondary)
        }
    }

    /// the upgrade may have already landed: brew replaces the bundle under a
    /// running app, so ask the disk before asking github. costs one plist
    /// read and no network.
    private func noteAnyUpgradeOnDisk() {
        guard let installed = UpdateCheck.installedVersion(
            atBundle: Bundle.main.bundleURL
        ),
            UpdateCheck.isNewer(tag: installed, than: version)
        else {
            return
        }
        updateStatus = .alreadyInstalled(installed)
    }

    private func checkForUpdates() {
        noteAnyUpgradeOnDisk()
        if case .alreadyInstalled = updateStatus {
            return
        }

        updateStatus = .checking
        Task {
            do {
                let latest = try await UpdateCheck.fetchLatest()
                updateStatus = UpdateCheck.isNewer(
                    tag: latest.version,
                    than: version
                )
                    ? .newer(
                        UpdateCheck.numbers(in: latest.version)
                            .map(String.init)
                            .joined(separator: "."),
                        latest.page
                    )
                    : .upToDate
            } catch {
                updateStatus = .unreachable
            }
        }
    }

    private func copyVersion() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            "\(version) · build \(build)",
            forType: .string
        )
        versionCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            versionCopied = false
        }
    }

    private func copyUpgradeCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(UpdateCheck.upgradeCommand, forType: .string)
        upgradeCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            upgradeCopied = false
        }
    }
}
