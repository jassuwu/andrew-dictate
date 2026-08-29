import Foundation

/// The four ways a meeting's clock is written, in one place — the panel, the
/// menu, the file, and the history row were each spelling their own.
extension Duration {
    var totalSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// `00:07:12` — fixed width, so the text after it lines up.
    var stamp: String {
        let (h, m, s) = clockParts
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// `12:34`, and `1:02:03` once a meeting passes an hour. Hours are not
    /// padded — a leading zero would make an eleven-minute meeting look like
    /// it had been going all day.
    var runningClock: String {
        let (h, m, s) = clockParts
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// `1h 42m`, `12m`, `<1m` — how long, said the way a person would.
    var spoken: String {
        let minutes = max(0, Int(components.seconds / 60))
        guard minutes > 0 else { return "<1m" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var clockParts: (Int, Int, Int) {
        let total = max(0, Int(components.seconds))
        return (total / 3_600, (total % 3_600) / 60, total % 60)
    }
}
