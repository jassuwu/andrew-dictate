import AppKit
import SwiftUI

/// the meetings half of history. the same row idiom as dictations: the facts
/// on the left, and on hover the three things you came for — open, show in
/// finder, delete. a double-click on the row opens it too, the way every other
/// mac list of documents behaves.
struct MeetingsBrowserView: View {
    @ObservedObject var viewModel: MeetingsListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = viewModel.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(BrandUI.attention)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
            }

            // kept, not deleted, and never retried again — so this is the
            // only place it exists as far as anyone can tell.
            if viewModel.setAsideCount > 0, let folder = viewModel.setAsideFolder {
                HStack(spacing: 8) {
                    Text(
                        viewModel.setAsideCount == 1
                            ? "1 recording couldn't be transcribed"
                            : "\(viewModel.setAsideCount) recordings couldn't be transcribed"
                    )
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.attention)

                    Button("show in finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }

            if viewModel.filtered.isEmpty {
                // a search that found nothing is not an empty folder, and
                // must not read like one.
                Text(
                    viewModel.isSearching
                        ? "nothing matches “\(viewModel.trimmedQuery)”."
                        : "no meetings yet."
                )
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.filtered) { meeting in
                            MeetingRow(
                                meeting: meeting,
                                audioNote: viewModel.audioNote(for: meeting),
                                deleteAudio: { viewModel.deleteAudio(of: meeting) },
                                delete: { viewModel.delete(meeting) }
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
    }
}

private struct MeetingRow: View {
    let meeting: MeetingSummary
    /// `audio until fri 14:02`, `audio kept`, or nil when there is none.
    let audioNote: String?
    let deleteAudio: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 8) {
                Text(
                    meeting.started.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .foregroundStyle(BrandUI.textPrimary)

                separator
                Text(meeting.app)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)

                separator
                Text(meeting.duration.spoken)
                    .font(BrandUI.machineFont(size: 12))
                    .foregroundStyle(BrandUI.textSecondary)

                separator
                Text(completeness.text)
                    .foregroundStyle(completeness.tint)

                // the audio is on this mac for a while yet: said on the
                // row, so nobody has to go looking to know it is there.
                if let audioNote {
                    separator
                    Text(audioNote)
                        .foregroundStyle(BrandUI.textSecondary)
                        .lineLimit(1)
                }
            }
            .font(BrandUI.bodyFont)

            Spacer(minLength: 8)

            // actions appear on hover: a list that grows for years should
            // not be a wall of buttons.
            HStack(spacing: 6) {
                Button("open", action: open)
                    .help("open the transcript")
                Button("show in finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [meeting.fileURL]
                    )
                }
                if audioNote != nil {
                    Button("delete audio now", action: deleteAudio)
                        .help("the transcript stays")
                }
                Button("delete", action: delete)
            }
            .font(.caption)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onHover { isHovering = $0 }
    }

    /// the file *is* the artifact (ADR 0040), so this hands it to whatever
    /// markdown app the user already has — there is no reader of our own to
    /// keep. a file renamed since the folder was read reveals where it was,
    /// rather than being a click that does nothing.
    private func open() {
        guard !NSWorkspace.shared.open(meeting.fileURL) else { return }

        let stillThere = FileManager.default.fileExists(
            atPath: meeting.fileURL.path(percentEncoded: false)
        )
        NSWorkspace.shared.activateFileViewerSelecting([
            stillThere
                ? meeting.fileURL
                : meeting.fileURL.deletingLastPathComponent()
        ])
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(BrandUI.textSecondary)
            .accessibilityHidden(true)
    }

    /// SPEC §4 for recordings: one with holes in it is never handed back
    /// looking whole, so anything short of complete is drawn in attention.
    private var completeness: (text: String, tint: Color) {
        if meeting.recovered {
            return ("recovered", BrandUI.attention)
        }
        if meeting.gapCount > 0 {
            return (
                meeting.gapCount == 1 ? "1 gap" : "\(meeting.gapCount) gaps",
                BrandUI.attention
            )
        }
        if !meeting.complete {
            return ("incomplete", BrandUI.attention)
        }
        return ("complete", BrandUI.textSecondary)
    }
}

#Preview("meetings") {
    MeetingsBrowserView(
        viewModel: MeetingsListModel {
            [
                MeetingSummary(
                    fileURL: URL(
                        fileURLWithPath:
                            "/tmp/2026-08-29-1402-zoom.md"
                    ),
                    app: "zoom",
                    started: .now,
                    duration: .seconds(6120),
                    complete: true,
                    gapCount: 0,
                    recovered: false
                ),
                MeetingSummary(
                    fileURL: URL(
                        fileURLWithPath:
                            "/tmp/2026-08-28-0930-chrome.md"
                    ),
                    app: "chrome",
                    started: .now.addingTimeInterval(-90000),
                    duration: .seconds(720),
                    complete: false,
                    gapCount: 2,
                    recovered: false
                ),
            ]
        }
    )
    .frame(width: 800, height: 330)
    .background(BrandUI.windowBg)
    .font(BrandUI.bodyFont)
    .brandTinted()
    .controlSize(.small)
    .preferredColorScheme(.dark)
}
