import Foundation

/// The about window's question, asked only when the user clicks: is there
/// a newer release? It asks github directly. The automatic once-a-day check
/// is `DailyUpdateCheck`, which asks dictate.jass.gg and never github; the
/// version parsing here serves both.
enum UpdateCheck {
    struct Latest: Equatable, Sendable {
        let version: String
        let page: URL
    }

    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/jassuwu/"
            + "andrew-dictate/releases/latest"
    )!

    /// The one line that updates it. Every copy was installed with a brew
    /// command, so the update is a brew command — and `brew upgrade` carries
    /// the gatekeeper approval and the microphone / accessibility grants to
    /// the new version, so there is no `xattr` line to run afterwards.
    static let upgradeCommand = "brew upgrade --cask jassuwu/tap/andrew-dictate"

    /// What is in /Applications *now*, which is not what this process
    /// launched with: brew replaces the bundle under a running app, and
    /// `Bundle.main`'s Info.plist was cached at launch. Read fresh off disk,
    /// so the old process can stop offering an update it is standing on.
    ///
    /// Any failure is `nil`. A dev build, a bundle run from a build folder or
    /// one the user moved must never produce a phantom "already installed".
    static func installedVersion(atBundle url: URL) -> String? {
        let plist = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plist) else {
            return nil
        }
        let parsed = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let root = parsed as? [String: Any],
              let version = root["CFBundleShortVersionString"] as? String
        else {
            return nil
        }
        return version
    }

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
