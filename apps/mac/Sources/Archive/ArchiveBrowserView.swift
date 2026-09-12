import AppKit
import SwiftUI

/// history: what it kept, and the only place to delete one of them.
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

            if viewModel.filtered.isEmpty {
                // a search that found nothing is not an empty archive, and
                // must not read like one.
                Text(
                    viewModel.isSearching
                        ? "nothing matches “\(viewModel.trimmedQuery)”."
                        : "nothing kept yet."
                )
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.filtered) { item in
                            ArchiveRow(
                                dictation: item,
                                query: viewModel.trimmedQuery,
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
        .preferredColorScheme(.dark)
        .onAppear { viewModel.reload() }
    }
}

private struct ArchiveRow: View {
    let dictation: Dictation
    /// what the search field holds, already trimmed. empty when no search is
    /// on, which is most of the time.
    let query: String
    let fixAWord: () -> Void
    let delete: () -> Void

    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(highlighted(dictation.inserted))
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
                    // While a search is on it is always shown, and shown
                    // longer: the word being hunted for often lives only here.
                    if isSearching || dictation.heard != dictation.inserted {
                        Text(heardLine)
                            .lineLimit(isSearching ? 2 : 1)
                    }
                }
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
            }

            Spacer(minLength: 8)

            // Actions appear on hover: a list of hundreds of rows should not
            // be a wall of buttons.
            HStack(spacing: 6) {
                Button(action: copy) {
                    // the label says it happened, in place. a pinned width
                    // keeps the two buttons beside it from shifting.
                    Text(copied ? "copied" : "copy")
                        .frame(width: 44, alignment: .leading)
                }
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

    private var isSearching: Bool { !query.isEmpty }

    private var heardLine: AttributedString {
        var line = AttributedString("heard “")
        line += highlighted(dictation.heard)
        line += AttributedString("”")
        return line
    }

    /// the matched run in gold: a hit you still have to hunt for on the line
    /// is not much of a hit. matched the way the filter matches — case- and
    /// diacritic-insensitive — or the highlight would miss what the list found.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard isSearching else { return out }

        var from = text.startIndex
        while let found = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: from..<text.endIndex
        ) {
            if let lower = AttributedString.Index(found.lowerBound, within: out),
               let upper = AttributedString.Index(found.upperBound, within: out) {
                out[lower..<upper].mergeAttributes(Self.ink(BrandUI.gold))
            }
            from = found.upperBound
        }
        return out
    }

    // typed subscript rather than a key path: the key-path spelling trips a
    // non-Sendable warning under strict concurrency (as in PipelineView).
    private static func ink(_ color: Color) -> AttributeContainer {
        var container = AttributeContainer()
        container[
            AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self
        ] = color
        return container
    }

    /// the archive keeping ADR 0030's promise: "wanting it again is what the
    /// archive is for". the inserted text is the paragraph that went into the
    /// wrong window, so that is the one that comes back — the raw text is what
    /// `fix a word` already carries.
    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(dictation.inserted, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

