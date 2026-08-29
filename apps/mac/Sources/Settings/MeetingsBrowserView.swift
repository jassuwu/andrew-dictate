import AppKit
import SwiftUI

/// the meetings half of history. the same row idiom as dictations: the facts
/// on the left, the two things you came for revealed on hover.
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

            if viewModel.items.isEmpty {
                Text("no meetings yet.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.items) { meeting in
                            MeetingRow(
                                meeting: meeting,
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
                Text(meetingLength(meeting.duration))
                    .font(BrandUI.machineFont(size: 12))
                    .foregroundStyle(BrandUI.textSecondary)

                separator
                Text(completeness.text)
                    .foregroundStyle(completeness.tint)
            }
            .font(BrandUI.bodyFont)

            Spacer(minLength: 8)

            // actions appear on hover: a list that grows for years should
            // not be a wall of buttons.
            HStack(spacing: 6) {
                Button("show in finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [meeting.fileURL]
                    )
                }
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

/// "1h 42m" / "12m" — how long a meeting is talked about, not seconds.
func meetingLength(_ duration: Duration) -> String {
    let minutes = max(0, Int(duration.components.seconds / 60))
    guard minutes > 0 else {
        return "<1m"
    }
    let hours = minutes / 60
    return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
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
