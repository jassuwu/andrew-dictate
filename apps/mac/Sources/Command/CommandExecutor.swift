import AppKit
import Foundation

@MainActor
final class CommandExecutor {
    var onDelegate: ((String) async -> Void)?
    var onAsk: ((String) async -> Void)?
    var onScreenAsk: ((String, ScreenAskScope) async -> Void)?
    var onCustomActionGate: ((
        CustomActionInvocation,
        String
    ) async -> Void)?
    var onShell: ((String, String) async -> Void)?
    var onFeedback: ((String) async -> Void)?

    private let paster: Paster
    private let fileManager: FileManager
    private let workspace: NSWorkspace

    private var cachedApplications: [InstalledApp]?

    init(
        paster: Paster,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        self.paster = paster
        self.fileManager = fileManager
        self.workspace = workspace
    }

    func execute(_ command: RoutedCommand) async {
        refreshApplicationIndexIfNeeded()

        switch command {
        case let .custom(action, capturedArgument):
            await executeCustomAction(
                CustomActionInvocation(
                    action: action,
                    capturedArgument: capturedArgument
                )
            )
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
            _ = await paster.paste(text)
            await flash("→ type \(text)")
        case let .template(url, label):
            await openTemplate(url, label: label)
        case let .delegate(prompt):
            await onDelegate?(prompt)
        case let .ask(prompt):
            await onAsk?(prompt)
        case let .screenAsk(prompt, scope):
            await onScreenAsk?(prompt, scope)
        }
    }

    func executeCustomAction(
        _ invocation: CustomActionInvocation,
        bypassingGate: Bool = false
    ) async {
        let action = invocation.action
        let argument = invocation.capturedArgument
        let feedback = "→ \(action.trigger)"

        switch action.type {
        case .open:
            let target = CustomActionPayload.raw(
                action.payload,
                argument: argument
            )
            await openCustomTarget(target, feedback: feedback)

        case .url:
            guard let urlString = CustomActionPayload.url(
                action.payload,
                argument: argument
            ),
            let url = URL(string: urlString),
            url.scheme?.isEmpty == false else {
                await flash("couldn't open action url")
                return
            }

            if url.isHTTPOrHTTPS {
                guard workspace.open(url) else {
                    await flash("couldn't open action url")
                    return
                }
                await flash(feedback)
            } else if bypassingGate {
                guard workspace.open(url) else {
                    await flash("couldn't open action url")
                    return
                }
                await flash(feedback)
            } else {
                await onCustomActionGate?(
                    invocation,
                    "→ open \(urlString)"
                )
            }

        case .shortcut:
            let shortcutName = CustomActionPayload.raw(
                action.payload,
                argument: argument
            )
            if await runShortcut(
                named: shortcutName,
                input: argument
            ) {
                await flash(feedback)
            } else {
                await flash("couldn't run shortcut")
            }

        case .shell:
            let command = CustomActionPayload.shell(
                action.payload,
                argument: argument
            )
            if action.alwaysAllow || bypassingGate {
                await onShell?(command, action.trigger)
            } else {
                await onCustomActionGate?(
                    invocation,
                    "→ shell: \(command)"
                )
            }

        case .type:
            let text = CustomActionPayload.raw(
                action.payload,
                argument: argument
            )
            _ = await paster.paste(text)
            await flash(feedback)

        case .ask:
            let prompt = CustomActionPayload.raw(
                action.payload,
                argument: argument
            )
            if action.alwaysAllow || bypassingGate {
                await onAsk?(prompt)
            } else {
                await onCustomActionGate?(
                    invocation,
                    "→ ask: \(prompt)"
                )
            }
        }
    }

    private func openCustomTarget(
        _ target: String,
        feedback: String
    ) async {
        if let fileURL = fileURLIfTargetLooksLikePath(target) {
            guard workspace.open(fileURL) else {
                await flash("couldn't open \(target)")
                return
            }
            await flash(feedback)
            return
        }

        guard let application = resolveApplication(target) else {
            await flash("no app matching '\(target)'")
            return
        }

        do {
            _ = try await workspace.openApplication(
                at: application.url,
                configuration: NSWorkspace.OpenConfiguration()
            )
            await flash(feedback)
        } catch {
            print(
                "custom app open failed for \(application.displayName): "
                    + error.localizedDescription
            )
            await flash("couldn't open \(application.displayName)")
        }
    }

    private func fileURLIfTargetLooksLikePath(
        _ target: String
    ) -> URL? {
        let trimmed = target.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }

        let looksLikePath =
            trimmed.hasPrefix("/")
            || trimmed.hasPrefix("~/")
            || trimmed.hasPrefix("./")
            || trimmed.hasPrefix("../")
        guard looksLikePath else {
            return nil
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private func runShortcut(
        named shortcutName: String,
        input: String?
    ) async -> Bool {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/shortcuts"
        )
        process.arguments = ["run", shortcutName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.arguments? += ["-i", "-"]
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(
                    returning: finishedProcess.terminationStatus == 0
                )
            }

            do {
                try process.run()
                if let input, let inputPipe {
                    inputPipe.fileHandleForWriting.write(
                        Data(input.utf8)
                    )
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
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
              url.isHTTPOrHTTPS,
              workspace.open(url) else {
            await flash("couldn't open \(urlString)")
            return
        }

        await flash(feedback)
    }

    private func openTemplate(_ url: URL, label: String) async {
        guard url.isHTTPOrHTTPS, workspace.open(url) else {
            await flash("couldn't open \(label)")
            return
        }
        await flash("→ \(label)")
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
        await onFeedback?(message)
    }
}
