import Foundation

/// A meeting transcript as the history pane lists it: the front matter,
/// without reading the body. `fileURL` is the identity — the file *is* the
/// artifact (ADR 0040), so there is no id apart from where it lives.
struct MeetingSummary: Identifiable, Equatable, Sendable {
    var id: URL { fileURL }

    let fileURL: URL
    /// The app that was tapped, as shown to people: "zoom", "chrome".
    let app: String
    let started: Date
    let duration: Duration
    /// False when a rebuild left holes — never handed back looking whole.
    let complete: Bool
    let gapCount: Int
    /// The spool outlived the app and was transcribed at the next launch.
    let recovered: Bool
}
