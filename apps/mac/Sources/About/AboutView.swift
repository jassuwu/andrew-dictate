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
        let size = NSSize(width: 380, height: 460)
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
                Image("Badge")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)

                Text("Andrew Dictate")
                    .font(BrandUI.titleFont)
                    .foregroundStyle(BrandUI.textPrimary)
                    .padding(.top, 5)

                Text("escape the keyboard.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandUI.gold)
                    .padding(.top, 3)

                Text("version \(version) · build \(build)")
                    .font(BrandUI.valueFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .padding(.top, 6)

                Text(lifetimeWordsText)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandUI.goldPale)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 11)

                Rectangle()
                    .fill(BrandUI.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 14)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    attribution(
                        "FluidAudio",
                        license: "Apache-2.0",
                        url:
                            "https://github.com/FluidInference/"
                            + "FluidAudio"
                    )

                    attribution(
                        "NVIDIA Parakeet weights",
                        license: "CC-BY-4.0",
                        url:
                            "https://huggingface.co/nvidia/"
                            + "parakeet-tdt-0.6b-v2"
                    )

                    attribution(
                        "MIT license",
                        license: "open source",
                        url:
                            "https://github.com/jassuwu/"
                            + "andrew-dictate/blob/main/LICENSE"
                    )
                }

                Spacer(minLength: 8)

                Link(
                    "made by jass",
                    destination: URL(string: "https://jass.gg")!
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BrandUI.gold)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .frame(width: 380, height: 460)
        .background(BrandUI.windowBg)
        .preferredColorScheme(.dark)
    }

    private var lifetimeWordsText: String {
        let count = settings.totalWordsDictated.formatted(
            .number.grouping(.automatic)
        )
        return "andrew has typed \(count) words. undefeated."
    }

    private func attribution(
        _ name: String,
        license: String,
        url: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Link(name, destination: URL(string: url)!)
                .foregroundStyle(BrandUI.gold)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(license)
                .font(BrandUI.valueFont)
                .foregroundStyle(BrandUI.textSecondary)
                .lineLimit(1)
        }
        .font(BrandUI.bodyFont)
    }
}
