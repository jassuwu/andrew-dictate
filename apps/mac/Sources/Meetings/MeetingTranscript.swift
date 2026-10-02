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
    /// Why the file does not cover the meeting, in one sentence, for the front
    /// matter. nil gets the default, that audio was lost in N gaps. Only
    /// written when `complete` is false.
    var reason: String? = nil
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

    private static let paragraphSpan = Duration.seconds(60)
    /// The longest stretch a model is handed is about 25 s, so talk that
    /// carries on has its turns begin closer together than this.
    private static let sameBreath = Duration.seconds(30)

    /// Sits in `meetings/` beside the month folders. Never a meeting: it has
    /// no front matter, so `listAll` passes over it.
    static let noteName = "README.md"

    // one literal, not a chain: CI's Xcode gives up on a long `+` of strings.
    private static let noteText = """
    # meeting transcripts

    written by andrew dictate. one file per meeting, never changed after it is written.

    ## where things are

    meetings/YYYY-MM/YYYY-MM-DD-HHmm-app.md

    names sort by time, so the newest meeting is the last file in the last folder. `app` is the call app, or `meeting`.

    ## the top of each file

    - `app`: the call app.
    - `started`, `ended`: local time with offset.
    - `duration_s`: length in seconds.
    - `engine`: the speech model that wrote it.
    - `speakers`: who appears in the file. `you` is the mic. `them`, `them 1`, `them 2` are the other side.
    - `words`: how many words the transcript has.
    - `complete`: false if any audio was lost or the transcript does not cover what was said. `reason` says why.
    - `gaps`: stretches of lost audio, as [start, end] in seconds from the start.
    - `recovered`: true if the app wrote this at a later launch, after a crash.

    ## the rest

    one paragraph per speaker turn: `[hh:mm:ss] speaker: text`. times count from the start of the meeting.

    """

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
            "ended: \(iso8601(timeZone).string(from: ended(transcript)))",
            "duration_s: \(seconds(transcript.duration))",
            "engine: \(transcript.engine)",
            "speakers: [\(speakers(of: transcript).joined(separator: ", "))]",
            "words: \(wordCount(of: transcript))",
            "complete: \(transcript.complete)",
        ]
        if !transcript.complete {
            lines.append("reason: \(transcript.reason ?? lostAudio(transcript.gaps.count))")
        }
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

        for paragraph in paragraphs(of: transcript.turns) {
            lines.append(
                "[\(paragraph.at.stamp)] \(paragraph.speaker.label): \(paragraph.text)")
            lines.append("")
        }
        // every block above ends with an empty line, so the join already
        // closes the file with one newline.
        return lines.joined(separator: "\n")
    }

    /// The file is chmod 0600 and the two folders the app makes for it 0700.
    /// It holds other people's words, and the default 0644 would make that
    /// readable by every other account on the machine — the same rule the
    /// dictation archive, the spool and its audio already carry.
    ///
    /// Every permission call here is `try?` on purpose: a volume without
    /// POSIX modes must not turn a transcript that is already on disk into a
    /// `.saveFailed` and a spool the next launch writes out twice.
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
        let month = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: month,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try markdown(transcript, timeZone: timeZone)
            .write(to: url, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        // `createDirectory` only dresses the folders it had to make, so the
        // two the app owns are set every time. never `parent`: that one is
        // the user's, and they picked it.
        for folder in [month, month.deletingLastPathComponent()] {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        leaveNote(in: month.deletingLastPathComponent(), fileManager: fileManager)
        return url
    }

    /// The note beside the month folders, for an agent that is told "a
    /// meeting happened" and has nothing else to go on. Written once and
    /// never again: if it is there, it is whatever its owner made of it.
    /// `try?` for the same reason as the permissions: the transcript is
    /// already on disk, and a note is not worth a `.saveFailed`.
    private static func leaveNote(in folder: URL, fileManager: FileManager) {
        let note = folder.appendingPathComponent(noteName, isDirectory: false)
        guard !fileManager.fileExists(atPath: note.path) else { return }
        try? noteText.write(to: note, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: note.path)
    }

    /// The transcripts already on disk, written before the app locked them
    /// down. Run once at launch; a file it cannot touch is left as it is.
    static func lockDown(in parent: URL, fileManager: FileManager = .default) {
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        guard let enumerator = fileManager.enumerator(atPath: folder.path) else {
            return
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: folder.path)
        for case let relative as String in enumerator where !relative.hasPrefix(".") {
            let url = folder.appendingPathComponent(relative, isDirectory: false)
            if relative.hasSuffix(".md") {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }
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

    private static func lostAudio(_ gapCount: Int) -> String {
        "audio was lost in \(gapCount) \(gapCount == 1 ? "gap" : "gaps")"
    }

    /// The labels the body uses, each once, in the order they first speak.
    private static func speakers(of transcript: MeetingTranscript) -> [String] {
        var labels: [String] = []
        for turn in transcript.turns where !labels.contains(turn.speaker.label) {
            labels.append(turn.speaker.label)
        }
        return labels
    }

    /// Whitespace-separated, over what was said: not the labels or the stamps.
    private static func wordCount(of transcript: MeetingTranscript) -> Int {
        transcript.turns.reduce(0) { count, turn in
            count + turn.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    /// What one speaker said in a row, stamped with the first line's time —
    /// the live pass hands over fragments, and a person reads turns. A
    /// monologue starts a new paragraph a minute after the last one began, so
    /// there is always a time within a minute of whatever you are looking for.
    /// So does talk that picks up again after a silence: a turn only has the
    /// time it began, and one that begins more than `sameBreath` after the
    /// one before it began was not said in the same breath.
    private static func paragraphs(of turns: [MeetingTurn]) -> [MeetingTurn] {
        var out: [MeetingTurn] = []
        var lastBegan: Duration = .zero
        for turn in turns {
            if let last = out.last, last.speaker == turn.speaker,
               turn.at - last.at < paragraphSpan,
               turn.at - lastBegan <= sameBreath {
                out[out.count - 1] = MeetingTurn(
                    speaker: last.speaker, at: last.at,
                    text: last.text + " " + turn.text)
            } else {
                out.append(turn)
            }
            lastBegan = turn.at
        }
        return out
    }

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }

    /// Worked out from the whole seconds the file shows for `started` and
    /// `duration_s`, so the three always add up. Adding the real fractions
    /// can land a second past what a reader gets by adding the two lines.
    private static func ended(_ transcript: MeetingTranscript) -> Date {
        Date(
            timeIntervalSince1970: transcript.started.timeIntervalSince1970.rounded(.down)
                + Double(seconds(transcript.duration)))
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
