import AppKit
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
        let size = NSSize(width: 300, height: 300)
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
        case unreachable
    }

    @ObservedObject private var settings: AppSettings
    @State private var showsRecord = false
    @State private var versionCopied = false
    @State private var updateStatus: UpdateStatus = .idle
    private let version: String
    private let build: String

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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BrandUI.textSecondary)
            }
            .buttonStyle(.plain)
            .help("click to copy")
            .padding(.top, 8)

            updatesLine
                .padding(.top, 7)

            Spacer(minLength: 12)

            Text(creditsMarkdown)
                .font(.system(size: 10.5))
                .foregroundStyle(BrandUI.textSecondary)
                .tint(BrandUI.gold.opacity(0.85))
                .help(
                    "FluidAudio: Apache-2.0 · "
                        + "parakeet weights: CC-BY-4.0 · "
                        + "this app: MIT"
                )

            Text(signatureMarkdown)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandUI.textSecondary)
                .tint(BrandUI.gold)
                .padding(.top, 5)
        }
        .padding(.top, 30)
        .padding(.bottom, 18)
        .padding(.horizontal, 16)
        .frame(width: 300, height: 300)
        .background(BrandUI.windowBg)
        .preferredColorScheme(.dark)
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

    private var creditsMarkdown: AttributedString {
        let markdown =
            "built on [FluidAudio]"
            + "(https://github.com/FluidInference/FluidAudio) "
            + "and [NVIDIA's parakeet]"
            + "(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)"
        return (try? AttributedString(markdown: markdown))
            ?? AttributedString("built on FluidAudio and parakeet")
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
                Link("\(version) is out — get it", destination: page)
                    .foregroundStyle(BrandUI.gold)

            case .unreachable:
                Text("couldn't check — try again later.")
                    .foregroundStyle(BrandUI.textSecondary)
            }
        }
        .font(.system(size: 11))
    }

    private func checkForUpdates() {
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
}
