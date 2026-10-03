import Foundation

/// One stretch of the far side the diarizer heard as one voice, on the
/// spool's clock. The id is the diarizer's own and means nothing outside the
/// meeting, but it holds from one piece of the meeting to the next.
struct SpeakerSegment: Equatable, Sendable {
    let speaker: String
    let from: Duration
    let to: Duration
}

/// The far side's turns given the voices the diarizer heard.
enum SpeakerTurns {
    /// Each `them` turn takes the voice whose segment covers where it starts,
    /// or failing one, the voice whose segment starts nearest it. The voices
    /// are numbered in the order they first speak among the turns, so a
    /// voice the diarizer found that never got a turn leaves no hole in the
    /// numbers. One voice among the turns leaves them plain `them`.
    static func assign(_ turns: [MeetingTurn], to segments: [SpeakerSegment]) -> [MeetingTurn] {
        guard !segments.isEmpty else { return turns }
        let voices = turns.map { turn -> String? in
            guard case .them = turn.speaker else { return nil }
            return voice(at: turn.at, in: segments)
        }
        guard Set(voices.compactMap { $0 }).count > 1 else { return turns }
        let numbers = firstAppearances(of: voices, at: turns.map(\.at))
        return zip(turns, voices).map { turn, voice in
            guard let voice, let number = numbers[voice] else { return turn }
            return turn.said(by: .them(number))
        }
    }

    /// The file's numbers, whoever gave the turns theirs: 1, 2, 3 in the
    /// order each first speaks, with no holes. Done last, after everything
    /// that can take a number away from a turn.
    static func numbered(_ turns: [MeetingTurn]) -> [MeetingTurn] {
        let given = turns.map { turn -> Int? in
            guard case .them(let number?) = turn.speaker else { return nil }
            return number
        }
        let numbers = firstAppearances(of: given, at: turns.map(\.at))
        return zip(turns, given).map { turn, number in
            guard let number, let renumbered = numbers[number] else { return turn }
            return turn.said(by: .them(renumbered))
        }
    }

    private static func voice(at: Duration, in segments: [SpeakerSegment]) -> String? {
        func distance(_ segment: SpeakerSegment) -> Duration {
            segment.from < at ? at - segment.from : segment.from - at
        }
        let covering = segments.first { $0.from <= at && at < $0.to }
            ?? segments.min { distance($0) < distance($1) }
        return covering?.speaker
    }

    /// 1, 2, 3… for each label in the order of the time it first appears.
    /// Two turns at one time keep the order they came in.
    private static func firstAppearances<Label: Hashable>(
        of labels: [Label?],
        at times: [Duration]
    ) -> [Label: Int] {
        let inOrder = labels.indices.sorted { (times[$0], $0) < (times[$1], $1) }
        var numbers: [Label: Int] = [:]
        for i in inOrder {
            guard let label = labels[i], numbers[label] == nil else { continue }
            numbers[label] = numbers.count + 1
        }
        return numbers
    }
}

extension MeetingTurn {
    /// The same turn, said by someone else: its times and words as they were.
    func said(by speaker: Speaker) -> MeetingTurn {
        MeetingTurn(speaker: speaker, at: at, text: text, end: end)
    }
}
