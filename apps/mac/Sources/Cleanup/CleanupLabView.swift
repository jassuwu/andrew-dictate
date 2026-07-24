import AppKit
import SwiftUI

@MainActor
final class CleanupLabWindowController: NSWindowController {
    private let viewModel: CleanupLabViewModel

    init(store: LabStore) {
        let viewModel = CleanupLabViewModel(store: store)
        self.viewModel = viewModel

        let rootView = CleanupLabView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "cleanup lab"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 660, height: 440)
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
        viewModel.reload()
    }

    func reload() {
        viewModel.reload()
    }
}

@MainActor
private final class CleanupLabViewModel: ObservableObject {
    @Published private(set) var entries: [CleanupLabEntry] = []
    @Published private(set) var isLoading = false

    private let store: LabStore
    private var loadTask: Task<Void, Never>?

    init(store: LabStore) {
        self.store = store
    }

    func reload() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self, store] in
            let entries = (try? await store.load()) ?? []
            guard !Task.isCancelled, let self else {
                return
            }
            self.entries = entries.reversed()
            self.isLoading = false
            self.loadTask = nil
        }
    }
}

private struct CleanupLabView: View {
    @ObservedObject var viewModel: CleanupLabViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("cleanup lab")
                    .font(BrandUI.titleFont)

                Spacer()

                Text("newest first · local only")
                    .font(BrandUI.valueFont)
                    .foregroundStyle(BrandUI.textSecondary)
            }

            if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(
                            Array(viewModel.entries.enumerated()),
                            id: \.offset
                        ) { _, entry in
                            labRow(entry)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(
            minWidth: 660,
            minHeight: 440,
            alignment: .topLeading
        )
        .background(BrandUI.windowBg)
        .foregroundStyle(BrandUI.textPrimary)
        .font(BrandUI.bodyFont)
        .brandTinted()
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        BrandCard {
            Text(
                viewModel.isLoading
                    ? "loading cleanup pairs…"
                    : "turn on ai cleanup and pairs appear here."
            )
            .foregroundStyle(BrandUI.textSecondary)
            .frame(
                maxWidth: .infinity,
                minHeight: 220,
                alignment: .center
            )
        }
    }

    private func labRow(_ entry: CleanupLabEntry) -> some View {
        BrandCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(
                        entry.ts.formatted(
                            date: .abbreviated,
                            time: .standard
                        )
                    )

                    Text(entry.backend)

                    Spacer()

                    Text(
                        String(format: "%.1f ms", entry.latencyMs)
                    )
                }
                .font(BrandUI.valueFont)
                .foregroundStyle(BrandUI.textSecondary)

                HStack(alignment: .top, spacing: 12) {
                    transcriptBlock("raw", text: entry.raw)
                    transcriptBlock("cleaned", text: entry.cleaned)
                }
            }
        }
    }

    private func transcriptBlock(
        _ label: String,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            BrandSectionHeader(label)

            Text(text)
                .textSelection(.enabled)
                .frame(
                    maxWidth: .infinity,
                    alignment: .topLeading
                )
                .padding(10)
                .background {
                    RoundedRectangle(
                        cornerRadius: 7,
                        style: .continuous
                    )
                    .fill(BrandUI.windowBg.opacity(0.72))
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 7,
                        style: .continuous
                    )
                    .stroke(BrandUI.hairline, lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
