import Foundation

/// The site keeps what its demos show in apps/site/src/demo, and tests here
/// hold those files to the app. This is where the files are.
enum SiteDemoFile {
    /// apps/mac/Tests/ → apps/site/src/demo/<name>
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("site/src/demo")
            .appendingPathComponent(name)
    }
}
