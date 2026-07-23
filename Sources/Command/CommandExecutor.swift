import AppKit
import Foundation

@MainActor
final class CommandExecutor {
    var onDelegate: ((String) async -> Void)?

    private let paster: Paster
    private let hudViewModel: HUDViewModel
    private let hudPanel: HUDPanel
    private let fileManager: FileManager
    private let workspace: NSWorkspace

    private var cachedApplications: [InstalledApp]?

    init(
        paster: Paster,
        hudViewModel: HUDViewModel,
        hudPanel: HUDPanel,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        self.paster = paster
        self.hudViewModel = hudViewModel
        self.hudPanel = hudPanel
        self.fileManager = fileManager
        self.workspace = workspace
    }

    func execute(_ command: RoutedCommand) async {
        refreshApplicationIndexIfNeeded()

        switch command {
        case let .openApp(query):
            await openApplication(matching: query)
        case let .switchToApp(query):
            await switchToApplication(matching: query)
        case let .quitApp(query):
            await quitApplication(matching: query)
        case let .goTo(urlString):
            await openURL(
                urlString,
                feedback: "→ go to \(urlString)"
            )
        case let .typeLiteral(text):
            await paster.paste(text)
            await flash("→ type \(text)")
        case let .template(url, label):
            if workspace.open(url) {
                await flash("→ \(label)")
            } else {
                await flash("couldn't open \(label)")
            }
        case let .delegate(prompt):
            await onDelegate?(prompt)
        }
    }

    private func openApplication(matching query: String) async {
        guard let application = resolveApplication(query) else {
            await flash("no app matching '\(query)'")
            return
        }

        do {
            _ = try await workspace.openApplication(
                at: application.url,
                configuration: NSWorkspace.OpenConfiguration()
            )
            await flash("→ open \(application.displayName)")
        } catch {
            print(
                "app open failed for \(application.displayName): "
                    + error.localizedDescription
            )
            await flash("couldn't open \(application.displayName)")
        }
    }

    private func switchToApplication(matching query: String) async {
        guard let application = resolveApplication(query) else {
            await flash("no app matching '\(query)'")
            return
        }

        if let runningApplication = runningApplication(for: application),
           runningApplication.activate(options: [.activateAllWindows]) {
            await flash("→ switch to \(application.displayName)")
            return
        }

        do {
            _ = try await workspace.openApplication(
                at: application.url,
                configuration: NSWorkspace.OpenConfiguration()
            )
            await flash("→ switch to \(application.displayName)")
        } catch {
            print(
                "app switch failed for \(application.displayName): "
                    + error.localizedDescription
            )
            await flash("couldn't switch to \(application.displayName)")
        }
    }

    private func quitApplication(matching query: String) async {
        guard let application = resolveApplication(query) else {
            await flash("no app matching '\(query)'")
            return
        }

        guard let runningApplication = runningApplication(for: application) else {
            await flash("\(application.displayName) isn't running")
            return
        }

        if runningApplication.terminate() {
            await flash("→ quit \(application.displayName)")
        } else {
            await flash("couldn't quit \(application.displayName)")
        }
    }

    private func openURL(
        _ urlString: String,
        feedback: String
    ) async {
        guard let url = URL(string: urlString),
              workspace.open(url) else {
            await flash("couldn't open \(urlString)")
            return
        }

        await flash(feedback)
    }

    private func resolveApplication(_ query: String) -> InstalledApp? {
        AppMatcher(applications: cachedApplications ?? []).match(query)
    }

    private func runningApplication(
        for application: InstalledApp
    ) -> NSRunningApplication? {
        if let bundleIdentifier = application.bundleIdentifier,
           let match = NSRunningApplication.runningApplications(
               withBundleIdentifier: bundleIdentifier
           ).first {
            return match
        }

        let applicationPath = application.url.standardizedFileURL.path
        if let match = workspace.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == applicationPath
        }) {
            return match
        }

        return workspace.runningApplications.first {
            $0.localizedName?.compare(
                application.displayName,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: Locale(identifier: "en_US_POSIX")
            ) == .orderedSame
        }
    }

    private func refreshApplicationIndexIfNeeded() {
        guard cachedApplications == nil else {
            return
        }

        cachedApplications = scanInstalledApplications()
    }

    private func scanInstalledApplications() -> [InstalledApp] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications",
                isDirectory: true
            ),
        ]

        var applications: [InstalledApp] = []
        var seenPaths: Set<String> = []

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    print(
                        "app scan skipped \(url.path): "
                            + error.localizedDescription
                    )
                    return true
                }
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.caseInsensitiveCompare("app")
                        == .orderedSame else {
                    continue
                }

                enumerator.skipDescendants()

                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else {
                    continue
                }

                applications.append(installedApplication(at: url))
            }
        }

        return applications.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return $0.url.path < $1.url.path
        }
    }

    private func installedApplication(at url: URL) -> InstalledApp {
        let bundle = Bundle(url: url)
        let displayName = (
            bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ) ?? (
            bundle?.infoDictionary?["CFBundleDisplayName"] as? String
        ) ?? (
            bundle?.localizedInfoDictionary?["CFBundleName"] as? String
        ) ?? (
            bundle?.infoDictionary?["CFBundleName"] as? String
        ) ?? url.deletingPathExtension().lastPathComponent

        return InstalledApp(
            displayName: displayName,
            url: url,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }

    private func flash(_ message: String) async {
        hudViewModel.showCommandFeedback(message)
        hudPanel.present()

        defer {
            hudViewModel.clearCommandFeedback()
            hudPanel.dismiss()
        }

        try? await Task.sleep(for: .milliseconds(1_200))
    }
}
