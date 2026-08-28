import AppKit
import SwiftUI

/// What it keeps, and the only place to delete one of them.
struct ArchiveBrowserView: View {
    @ObservedObject var viewModel: ArchiveBrowserViewModel
    let fixAWord: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = viewModel.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(BrandUI.attention)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
            }

            if viewModel.items.isEmpty {
                Text("nothing kept yet.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.items) { item in
                            ArchiveRow(
                                dictation: item,
                                fixAWord: { fixAWord(item.heard) },
                                delete: { viewModel.delete(item) }
                            )
                            Divider().overlay(BrandUI.hairline)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandUI.windowBg)
        .preferredColorScheme(.dark)
        .onAppear { viewModel.reload() }
    }
}

private struct ArchiveRow: View {
    let dictation: Dictation
    let fixAWord: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dictation.inserted)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textPrimary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(
                        dictation.startedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    // The raw text is only worth showing when the cleaner
                    // changed something; otherwise it is the same line twice.
                    if dictation.heard != dictation.inserted {
                        Text("heard “\(dictation.heard)”")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
            }

            Spacer(minLength: 8)

            // Actions appear on hover: a list of hundreds of rows should not
            // be a wall of buttons.
            HStack(spacing: 6) {
                Button("fix a word", action: fixAWord)
                Button("delete", action: delete)
            }
            .font(.caption)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

