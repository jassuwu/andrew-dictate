import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
    init(bundle: Bundle = .main) {
        let rootView = AboutView(bundle: bundle)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "about Andrew Dictate"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 390))
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

struct AboutView: View {
    private let version: String

    init(bundle: Bundle = .main) {
        let shortVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        if let shortVersion, let build {
            version = "\(shortVersion) (\(build))"
        } else {
            version = shortVersion ?? build ?? "development"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Andrew Dictate")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("free, open source, fully local dictation.")
                    .padding(.top, 4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("attributions")
                    .font(.headline)

                attribution(
                    "FluidAudio",
                    license: "Apache-2.0",
                    url: "https://github.com/FluidInference/FluidAudio"
                )

                attribution(
                    "NVIDIA Parakeet TDT 0.6B v2/v3 model weights",
                    license: "CC-BY-4.0",
                    url:
                        "https://huggingface.co/nvidia/"
                        + "parakeet-tdt-0.6b-v2"
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Andrew Dictate is available under the MIT license.")

                Link(
                    "github.com/jassuwu/andrew-dictate",
                    destination: URL(
                        string:
                            "https://github.com/jassuwu/"
                            + "andrew-dictate"
                    )!
                )
            }
            .font(.callout)

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 480, height: 390)
    }

    private func attribution(
        _ name: String,
        license: String,
        url: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Link(name, destination: URL(string: url)!)

            Spacer()

            Text(license)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
