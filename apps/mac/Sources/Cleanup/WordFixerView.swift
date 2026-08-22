import AppKit
import SwiftUI

struct WordFixerView: View {
    @ObservedObject var viewModel: WordFixerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("what it heard")
                .font(BrandUI.sectionLabelFont)
                .foregroundStyle(BrandUI.textSecondary)

            Text("click a word that came out wrong. click the one next to it to take both.")
                .font(.system(size: 12))
                .foregroundStyle(BrandUI.textSecondary)

            WordFlow(spacing: 4) {
                ForEach(viewModel.correction.spans) { span in
                    WordChip(
                        text: viewModel.saved[span.id] ?? span.text,
                        isSaved: viewModel.saved[span.id] != nil,
                        isSelected: isSelected(span.id)
                    ) {
                        viewModel.tap(span.id)
                    }
                }
            }

            Divider().overlay(BrandUI.hairline)

            if let phrase = viewModel.selectedPhrase {
                HStack(spacing: 8) {
                    Text("heard")
                        .foregroundStyle(BrandUI.textSecondary)
                    Text("“\(phrase)”")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(BrandUI.goldPale)
                    Text("→")
                        .foregroundStyle(BrandUI.textSecondary)
                    TextField("what you meant", text: $viewModel.replacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .onSubmit { viewModel.save() }
                    Button("save") { viewModel.save() }
                        .disabled(!viewModel.canSave)
                }
                .font(.system(size: 13))
            } else {
                Text("nothing picked yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(BrandUI.textSecondary)
            }

            if let failure = viewModel.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(BrandUI.attention)
            }

            Spacer(minLength: 0)

            Text("saved words are corrected from now on, everywhere.")
                .font(.system(size: 11))
                .foregroundStyle(BrandUI.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandUI.windowBg)
        .preferredColorScheme(.dark)
    }

    private func isSelected(_ index: Int) -> Bool {
        guard let first = viewModel.first, let last = viewModel.last else {
            return false
        }
        return (first...last).contains(index)
    }
}

private struct WordChip: View {
    let text: String
    let isSaved: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(isSaved ? BrandUI.gold : BrandUI.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? BrandUI.gold.opacity(0.2) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isSaved || isSelected ? BrandUI.gold : .clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isSaved)
    }
}

/// Words wrap like words. `HStack` would push a long transcript off the window.
private struct WordFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

@MainActor
final class WordFixerWindowController: NSWindowController {
    init(transcript: String, store: DictionaryStore) {
        let viewModel = WordFixerViewModel(transcript: transcript, store: store)
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: WordFixerView(viewModel: viewModel)
            )
        )
        window.title = "fix a word"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 340))
        window.minSize = NSSize(width: 420, height: 280)
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
