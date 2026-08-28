import AppKit
import SwiftUI

/// Leaving, made as easy as arriving.
struct RemovalView: View {
    @ObservedObject var viewModel: RemovalViewModel
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("remove what's on this mac")
                .font(BrandUI.titleFont)
                .foregroundStyle(BrandUI.textPrimary)

            if viewModel.hasAnythingToRemove {
                Text("everything is ticked. untick anything you want to keep.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
            } else {
                Text("there's nothing left to remove.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.entries) { entry in
                    RemovalRow(
                        entry: entry,
                        sizeText: viewModel.sizeText(for: entry),
                        isOn: viewModel.selection.contains(entry.item),
                        toggle: { viewModel.toggle(entry.item) }
                    )
                }
            }
            .padding(.vertical, 4)

            Divider().overlay(BrandUI.hairline)

            Toggle(
                "also move Andrew Dictate to the trash",
                isOn: $viewModel.alsoTrashTheApp
            )
            .font(BrandUI.bodyFont)

            // The one thing the app genuinely cannot do for you. Saying so
            // beats letting someone believe "no traces" covered it.
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS keeps the microphone and accessibility permissions.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
                Button("open privacy & security…") {
                    NSWorkspace.shared.open(
                        URL(
                            string: "x-apple.systempreferences:"
                                + "com.apple.preference.security?Privacy_Accessibility"
                        )!
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if let outcome = viewModel.outcome {
                Text(outcome)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(
                        outcome.hasPrefix("couldn")
                            ? BrandUI.attention
                            : BrandUI.gold
                    )
            }

            Spacer(minLength: 0)

            HStack {
                Text(
                    viewModel.selectedBytes > 0
                        ? "frees \(viewModel.selectedSizeText)"
                        : " "
                )
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)

                Spacer()

                Button("remove") { remove() }
                    .disabled(viewModel.selection.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandUI.windowBg)
        .preferredColorScheme(.dark)
        .onAppear { viewModel.reload() }
    }

    private func remove() {
        isWorking = true
        let failed = viewModel.removeSelected()
        let trash = viewModel.alsoTrashTheApp

        guard failed.isEmpty else {
            // Something is still on disk. Stay open and say which — quitting
            // here would look exactly like success.
            isWorking = false
            return
        }

        Task { @MainActor in
            // Long enough to read "removed. quitting."
            try? await Task.sleep(for: .milliseconds(900))
            if trash {
                try? await NSWorkspace.shared.recycle([Bundle.main.bundleURL])
            }
            NSApp.terminate(nil)
        }
    }
}

private struct RemovalRow: View {
    let entry: RemovalPlan.Entry
    let sizeText: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(get: { isOn }, set: { _ in toggle() })
            )
            .labelsHidden()
            .disabled(!entry.exists)
            .accessibilityLabel(entry.item.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.title)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(
                        entry.exists
                            ? BrandUI.textPrimary
                            : BrandUI.textSecondary
                    )
                if entry.exists, let caveat = entry.item.caveat {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(BrandUI.textSecondary)
                }
            }

            Spacer(minLength: 8)

            Text(sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(BrandUI.textSecondary)
        }
    }
}

@MainActor
final class RemovalWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: RemovalView(viewModel: RemovalViewModel())
            )
        )
        window.title = "remove"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 470))
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
