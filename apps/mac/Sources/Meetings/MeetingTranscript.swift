import Foundation

/// One turn of a meeting: who, when, what. `them(2)` is the diarizer's second
/// far-side voice; `them(nil)` is the far side before it has been split, or
/// when there was only ever one voice there.
struct MeetingTurn: Equatable, Sendable {
    enum Speaker: Equatable, Sendable {
        case you
        case them(Int?)

        var label: String {
            switch self {
            case .you: "you"
            case .them(nil): "them"
            case .them(let n?): "them \(n)"
            }
        }
    }

    let speaker: Speaker
    let at: Duration
    let text: String
}

/// A finished meeting, ready to become a file. The artifact is the transcript
/// (ADR 0040): no audio survives, so everything worth knowing is in here.
struct MeetingTranscript: Equatable, Sendable {
    let app: String
    let started: Date
    let duration: Duration
    let engine: String
    let gaps: [MeetingSession.Gap]
    let recovered: Bool
    let turns: [MeetingTurn]

    /// SPEC §4 extended: a transcript with holes says so, in its front matter
    /// and in its body.
    var complete: Bool { gaps.isEmpty }
}

/// The transcript on disk: `<parent>/meetings/2026-08/2026-08-29-1402-zoom.md`,
/// markdown with front matter. One file per meeting, nothing beside it, no
/// spaces in the name — a thing a person recognises in Finder and a script can
/// `cat`.
enum MeetingTranscriptFile {
    enum Failure: Error, Equatable {
        case noFrontMatter(URL)
        case malformed(String)
    }

    static let folderName = "meetings"

    // MARK: - naming

    static func slug(_ app: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in app.lowercased().unicodeScalars {
            let isKept = (scalar.value < 128)
                && (CharacterSet.alphanumerics.contains(scalar))
            if isKept {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "meeting" : out
    }

    static func fileURL(
        in parent: URL,
        started: Date,
        app: String,
        fileManager: FileManager = .default,
        timeZone: TimeZone = .current
    ) -> URL {
        let month = formatter("yyyy-MM", timeZone).string(from: started)
        let stem = formatter("yyyy-MM-dd-HHmm", timeZone).string(from: started)
            + "-" + slug(app)
        let folder = parent
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)

        var candidate = folder.appendingPathComponent("\(stem).md")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(n).md")
            n += 1
        }
        return candidate
    }

    // MARK: - rendering

    static func markdown(
        _ transcript: MeetingTranscript,
        timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = [
            "---",
            "app: \(transcript.app)",
            "started: \(iso8601(timeZone).string(from: transcript.started))",
            "duration_s: \(seconds(transcript.duration))",
            "engine: \(transcript.engine)",
            "complete: \(transcript.complete)",
        ]
        if transcript.gaps.isEmpty {
            lines.append("gaps: []")
        } else {
            lines.append("gaps:")
            for gap in transcript.gaps {
                lines.append(
                    "- [\(oneDecimal(gap.began)), \(oneDecimal(gap.ended))]")
            }
        }
        lines.append("recovered: \(transcript.recovered)")
        lines.append("---")
        lines.append("")

        if !transcript.gaps.isEmpty {
            let count = transcript.gaps.count
            let spans = transcript.gaps
                .map { "between \($0.began.stamp) and \($0.ended.stamp)" }
                .joined(separator: ", and ")
            lines.append(
                "> \(count) \(count == 1 ? "gap" : "gaps") — audio was lost \(spans)")
            lines.append("")
        }

        for turn in transcript.turns {
            lines.append("[\(turn.at.stamp)] \(turn.speaker.label): \(turn.text)")
            lines.append("")
        }
        // every block above ends with an empty line, so the join already
        // closes the file with one newline.
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func write(
        _ transcript: MeetingTranscript,
        in parent: URL,
        fileManager: FileManager = .default,
        timeZone: TimeZone = .current
    ) throws -> URL {
        let url = fileURL(
            in: parent, started: transcript.started, app: transcript.app,
            fileManager: fileManager, timeZone: timeZone)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try markdown(transcript, timeZone: timeZone)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - reading back

    /// Reads only the front matter. The body can be megabytes; the history
    /// pane needs six fields.
    static func summary(of url: URL) throws -> MeetingSummary {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.first == "---" else {
            throw Failure.noFrontMatter(url)
        }
        lines = lines.dropFirst()

        var fields: [String: String] = [:]
        var gapCount = 0
        var closed = false
        for line in lines {
            if line == "---" { closed = true; break }
            if line.hasPrefix("- [") { gapCount += 1; continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard closed else {
            throw Failure.noFrontMatter(url)
        }

        guard let app = fields["app"],
              let startedText = fields["started"],
              let started = iso8601(.current).date(from: startedText),
              let durationText = fields["duration_s"],
              let durationSeconds = Int64(durationText)
        else {
            throw Failure.malformed(url.lastPathComponent)
        }
        return MeetingSummary(
            fileURL: url,
            app: app,
            started: started,
            duration: .seconds(durationSeconds),
            complete: fields["complete"] == "true",
            gapCount: gapCount,
            recovered: fields["recovered"] == "true"
        )
    }

    static func listAll(
        in parent: URL,
        fileManager: FileManager = .default
    ) -> [MeetingSummary] {
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        // Relative paths, joined back onto `folder`: the URL-based enumerator
        // resolves symlinks (/private/var/…) and the result would never equal
        // the URL `write` handed out a moment ago.
        guard let enumerator = fileManager.enumerator(atPath: folder.path) else {
            return []
        }

        var found: [MeetingSummary] = []
        for case let relative as String in enumerator
        where relative.hasSuffix(".md") && !relative.hasPrefix(".") {
            let url = folder.appendingPathComponent(relative, isDirectory: false)
            if let summary = try? summary(of: url) {
                found.append(summary)
            }
        }
        return found.sorted { $0.started > $1.started }
    }

    // MARK: - formatting

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }

    private static func oneDecimal(_ duration: Duration) -> String {
        String(format: "%.1f", duration.totalSeconds)
    }

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f
    }

    private static func iso8601(_ timeZone: TimeZone) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f
    }
}
