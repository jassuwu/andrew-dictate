import Foundation

/// One question, asked only when the user clicks: is there a newer release?
/// No timers, no launch checks, no phoning home — the app's privacy claim
/// stays simple because this only ever runs by hand.
enum UpdateCheck {
    struct Latest: Equatable, Sendable {
        let version: String
        let page: URL
    }

    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/jassuwu/"
            + "andrew-dictate/releases/latest"
    )!

    /// `v0.8.0`-style tags against `CFBundleShortVersionString`. A tag that
    /// doesn't parse is never "newer" — a garbage response must not produce
    /// an upgrade prompt.
    static func isNewer(tag: String, than current: String) -> Bool {
        let candidate = numbers(in: tag)
        let installed = numbers(in: current)
        guard !candidate.isEmpty, !installed.isEmpty else {
            return false
        }

        let width = Swift.max(candidate.count, installed.count)
        for index in 0..<width {
            let lhs = index < candidate.count ? candidate[index] : 0
            let rhs = index < installed.count ? installed[index] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }
        return false
    }

    static func numbers(in tag: String) -> [Int] {
        let trimmed = tag.hasPrefix("v") || tag.hasPrefix("V")
            ? String(tag.dropFirst())
            : tag
        let parts = trimmed.split(separator: ".")
        let parsed = parts.compactMap { Int($0) }
        // "0.8.beta" must not silently become 0.8 — a partial parse is
        // no parse.
        return parsed.count == parts.count ? parsed : []
    }

    static func fetchLatest() async throws -> Latest {
        struct Release: Decodable {
            let tagName: String
            let htmlURL: URL

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }

        let (data, _) = try await URLSession.shared.data(
            from: latestReleaseURL
        )
        let release = try JSONDecoder().decode(Release.self, from: data)
        return Latest(version: release.tagName, page: release.htmlURL)
    }
}
