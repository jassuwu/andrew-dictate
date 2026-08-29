import SwiftUI

/// the live view (SPEC §11): interleaved `you` / `them` lines with
/// timestamps, confirmed text in ink and the tentative tail dimmed.
///
/// the dim is the whole point. whisper's streaming tail is a guess that keeps
/// being rewritten, and drawing it in the same ink as confirmed text would be
/// the meeting version of §4's forbidden shape — something unfinished looking
/// finished. two inks, borrowed from the pipeline's lit/unlit stages.
///
/// the list follows the newest line, but only while you are already at the
/// bottom. scrolling up is a statement that you are reading something, and a
/// panel that yanks you back down mid-sentence is unusable in the exact
/// situation it exists for.
struct LiveTranscriptView: View {
    @ObservedObject private var model: LiveTranscriptModel
    @State private var followsNewest = true

    init(model: LiveTranscriptModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(BrandUI.hairline)
            transcript
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .preferredColorScheme(.dark)
        .brandGlassWindow()
    }

    private var header: some View {
        Text("recording \(model.app) · \(clock)")
            .font(BrandUI.machineFont(size: 11))
            .foregroundStyle(BrandUI.textSecondary)
            .lineLimit(1)
            // clears the close button of the transparent utility titlebar,
            // which the content is drawn underneath.
            .padding(.leading, 52)
            .padding(.trailing, 14)
            .padding(.top, 8)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clock: String {
        LiveTranscriptModel.clockText(model.elapsed)
    }

    @ViewBuilder
    private var transcript: some View {
        if model.lines.isEmpty {
            Text("listening…")
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(model.lines) { line in
                            row(line)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let bottom = geometry.contentOffset.y
                        + geometry.containerSize.height
                    return bottom >= geometry.contentSize.height - 24
                } action: { _, isAtBottom in
                    followsNewest = isAtBottom
                }
                .onChange(of: model.lines) { _, lines in
                    guard followsNewest, let newest = lines.last else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(newest.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard let newest = model.lines.last else {
                        return
                    }
                    proxy.scrollTo(newest.id, anchor: .bottom)
                }
            }
        }
    }

    private func row(_ line: LiveLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("[\(LiveTranscriptModel.stampText(line.at))]")
                .font(BrandUI.machineFont(size: 10))
                .foregroundStyle(BrandUI.textSecondary)

            Text(label(line.speaker))
                .font(BrandUI.machineFont(size: 10))
                .foregroundStyle(ink(line.speaker))
                .frame(width: 32, alignment: .leading)

            Text(line.text)
                .font(BrandUI.bodyFont)
                .foregroundStyle(
                    line.isConfirmed
                        ? BrandUI.textPrimary
                        : BrandUI.textSecondary
                )
                .opacity(line.isConfirmed ? 1 : 0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ speaker: LiveLine.Speaker) -> String {
        switch speaker {
        case .you: "you"
        case .them: "them"
        }
    }

    /// gold is the app's "this is the other side" mark, the same gold the lamp
    /// and the badge use; your own voice stays quiet.
    private func ink(_ speaker: LiveLine.Speaker) -> Color {
        switch speaker {
        case .you: BrandUI.textSecondary
        case .them: BrandUI.gold
        }
    }
}

#if DEBUG
private struct LiveTranscriptPreview: View {
    @StateObject private var model = LiveTranscriptModel(
        app: "zoom",
        elapsed: .seconds(754),
        lines: [
            LiveLine(
                speaker: .them,
                at: .seconds(4),
                text: "okay, i think we're all here.",
                isConfirmed: true
            ),
            LiveLine(
                speaker: .you,
                at: .seconds(9),
                text: "yeah — give me a second, sharing my screen.",
                isConfirmed: true
            ),
            LiveLine(
                speaker: .them,
                at: .seconds(21),
                text: "no rush. did the export land last night?",
                isConfirmed: true
            ),
            LiveLine(
                speaker: .you,
                at: .seconds(28),
                text: "it did, but the last two rows came through empty "
                    + "so i re-ran it this morning.",
                isConfirmed: true
            ),
            LiveLine(
                speaker: .them,
                at: .seconds(41),
                text: "right, so the thing we should probably decide",
                isConfirmed: false
            ),
            LiveLine(
                speaker: .you,
                at: .seconds(46),
                text: "is whether we",
                isConfirmed: false
            ),
        ]
    )

    var body: some View {
        LiveTranscriptView(model: model)
            .frame(width: 380, height: 280)
    }
}

#Preview {
    LiveTranscriptPreview()
}
#endif
