import AppKit
import SwiftUI

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
        window.styleMask = [.titled, .closable]
        let size = NSSize(width: 380, height: 360)
        window.setContentSize(size)
        window.minSize = size
        window.maxSize = size
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
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
    @ObservedObject private var settings: AppSettings
    @State private var showsRecord = false
    @State private var versionCopied = false
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
        BrandCard {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        showsRecord.toggle()
                    }
                } label: {
                    Image("Badge")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 120, height: 120)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("andrew")

                Text("Andrew Dictate")
                    .font(BrandUI.titleFont)
                    .foregroundStyle(BrandUI.textPrimary)
                    .padding(.top, 5)

                taglineOrRecord
                    .padding(.top, 3)

                Button {
                    copyVersion()
                } label: {
                    Text(
                        versionCopied
                            ? "copied"
                            : "version \(version) · build \(build)"
                    )
                    .font(BrandUI.valueFont)
                    .foregroundStyle(BrandUI.textSecondary)
                }
                .buttonStyle(.plain)
                .help("click to copy")
                .padding(.top, 6)

                Spacer(minLength: 14)

                Text(creditsMarkdown)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandUI.textSecondary)
                    .tint(BrandUI.gold.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .help(
                        "FluidAudio: Apache-2.0 · "
                            + "parakeet weights: CC-BY-4.0 · "
                            + "this app: MIT"
                    )

                Link(
                    "made by jass",
                    destination: URL(string: "https://jass.gg")!
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BrandUI.gold)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .frame(width: 380, height: 360)
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
        .font(.system(size: 13, weight: .medium))
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
            "[open source]"
            + "(https://github.com/jassuwu/andrew-dictate). "
            + "built on [FluidAudio]"
            + "(https://github.com/FluidInference/FluidAudio) "
            + "and [NVIDIA's parakeet]"
            + "(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)."
        return (try? AttributedString(markdown: markdown))
            ?? AttributedString("open source.")
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
