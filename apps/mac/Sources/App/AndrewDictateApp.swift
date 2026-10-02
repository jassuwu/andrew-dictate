import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by a second copy on its way out, so the copy already living in
    /// the menu bar can say where it is. The bundle id is interpolated
    /// because this is a machine-wide bus: the development build and the
    /// release build must not answer each other.
    static let andrewDictateAlreadyRunning = Notification.Name(
        "\(AppIdentity.bundleID).alreadyRunning"
    )
}

/// a menu-bar app is never "opened" twice — double-clicking it in
/// /Applications sends a reopen to the instance already running. that is the
/// user coming back to us, and the moment to re-verify what we're allowed to do.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    var onTerminate: (() -> NSApplication.TerminateReply)?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        onReopen?()
        return true
    }

    /// One archive, one spool, one pasteboard. A second copy — the dmg you
    /// opened to see what changed, still running from /Volumes — sweeps the
    /// live meeting spool as an orphan and deletes it out from under the copy
    /// recording into it. `willFinish`, not `didFinish`: the coordinator that
    /// opens the archive, installs the monitors and sweeps the spool is built
    /// when the scene body first runs, so there is nothing here to unwind.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Capabilities.current.refusesASecondInstance,
              let other = Self.otherRunningCopy()
        else {
            return
        }
        // it cannot say anything itself — it is about to be gone — so the
        // copy that is running draws the pill.
        DistributedNotificationCenter.default().postNotificationName(
            .andrewDictateAlreadyRunning,
            object: nil,
            deliverImmediately: true
        )
        _ = other.activate()
        exit(0)
    }

    /// A copy of this app that is neither this process nor already gone.
    private static func otherRunningCopy() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// on upgrade day the quit does not come from the menu: brew asks the app
    /// to go so it can replace the bundle under it. that request can land in
    /// the middle of a meeting, so it goes through the coordinator, which
    /// stops the recording and waits for the markdown before answering.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        onTerminate?() ?? .terminateNow
    }
}

@main
@MainActor
struct AndrewDictateApp: App {
    @StateObject private var coordinator = DictationCoordinator()
    @StateObject private var updates = DailyUpdateCheck.live()
    /// what clicking the update line does: a brew install runs the upgrade
    /// and the line follows it; a dmg install opens the releases page.
    @StateObject private var updateHandOff = UpdateHandOff.live()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate

    /// the badge carries hue and corner and nothing else. voiceover gets the
    /// sentence, including which mic is live.
    private var menuBarLabel: String {
        if coordinator.needsAttention {
            return "Andrew Dictate — setup needed"
        }
        if coordinator.meetings.isRecording {
            return "Andrew Dictate — recording a meeting"
        }
        return "Andrew Dictate"
    }

    var body: some Scene {
        MenuBarExtra {
            // two menu bar icons that look identical is a bad time. the badge
            // itself stays untouched — the logo is the logo (ADR 0013) — so the
            // marker goes in the menu instead.
            if Capabilities.current.announcesItself {
                Text("dev build — \(AppIdentity.bundleID)")
                    .foregroundStyle(.secondary)
                    .disabled(true)
                Divider()
            }

            // Only when it is *not* ready. A line reading "ready" forever is
            // furniture; a line that appears when the model is still loading
            // is the one thing the badge cannot tell you, because prewarming
            // and idle draw the same icon.
            if coordinator.state != .idle {
                Text(coordinator.state.displayName)
                    .foregroundStyle(.secondary)
                    .disabled(true)
            }

            // a meeting owns the mic and the menu while it runs (ADR 0023):
            // the state line, the stop, the live view. dictation's row goes,
            // because dictation is refused until you stop.
            if coordinator.meetings.isRecording {
                Text("recording · \(coordinator.meetings.elapsed.runningClock)")
                    .foregroundStyle(.secondary)
                    .disabled(true)

                Button("stop recording") {
                    coordinator.stopMeeting()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button(
                    coordinator.isLiveTranscriptShown
                        ? "hide live transcript"
                        : "live transcript"
                ) {
                    coordinator.toggleLiveTranscript()
                }
            } else {
                // a spool the app died on is being written out in the
                // background. the pill says it once; this says it for as
                // long as it runs.
                if let app = coordinator.meetings.recovering {
                    Text("writing out an unsaved \(app) recording…")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                }

                // a meeting leaves one file and no other trace on screen.
                // for ten minutes it is the thing you came back for; after
                // that the menu is the hand it was.
                if coordinator.showsLastMeetingRow {
                    Button("show last meeting in finder") {
                        coordinator.revealLastMeeting()
                    }
                }

                // The only action here that is time-sensitive: you just
                // watched it mishear a name. Everything else the app can do
                // is configuration or curiosity, and lives in settings
                // (ADR 0030).
                Button("fix a word…") {
                    coordinator.openWordFixer()
                }
                .disabled(coordinator.lastHeard == nil)
                // the only disabled case left is an empty archive, and a
                // dead row with no sentence explains nothing.
                .help("after your first dictation — this teaches andrew the word it got wrong.")

                // the second time-sensitive row, and it disappears on its
                // own: the samples of the sentence the model threw on are
                // still in memory for two minutes.
                if coordinator.canRetryLastFailure {
                    Button("try that again") {
                        coordinator.retryLastFailure()
                    }
                }

                // the third, and it goes on its own too: a word the app
                // just learned from your fixes, taken back in one click for
                // two minutes. after that it is a row in the dictionary tab.
                if let learned = coordinator.undoableLearning {
                    Button("undo learned: \(learned.right)") {
                        coordinator.undoLearning()
                    }
                }

                // nothing starts a recording but the user (ADR 0023), and
                // there is no app to name: a meeting hears the whole mac
                // (ADR 0049), so whatever the call is in is already heard.
                Button("record a meeting") {
                    coordinator.startMeeting()
                }

                // one row, and only while it is needed: the tap would not
                // open, and the window that can fix it was closed.
                if coordinator.meetingsNeedAttention {
                    Button("fix system audio…") {
                        coordinator.runOnboardingAgain(
                            scope: .meetingsOnly, openAt: .permissions)
                    }
                }
            }

            Divider()

            SettingsLink {
                Text("settings…")
            }
            .keyboardShortcut(",")

            // Zero rows when everything works, one click when it does not.
            // SPEC §5 makes settings the router; this is the shortcut for the
            // case where the user has no reason to go looking.
            if coordinator.needsAttention {
                Button("finish setup") {
                    coordinator.runOnboardingAgain()
                }
            }

            if Capabilities.current.canResetInPlace {
                Button("reset & relaunch (dev)") {
                    coordinator.resetInPlaceForDevelopment()
                }
            }

            #if DEBUG
            if Capabilities.current.hasLampLab {
                Button("lamp lab (dev)") {
                    coordinator.openLampLab()
                }
                Button("rehearse the lamp (dev)") {
                    coordinator.rehearseHUDForDevelopment()
                }
            }
            #endif

            Divider()

            // a newer version is a line here and nothing else (ADR 0043):
            // no dot on the badge, because a dot means the app needs you
            // and an old version still works. a meeting owns the menu while
            // it runs, so the line waits for it. once clicked, the line is
            // the upgrade's progress: the menu is where the click was.
            if let line = updateHandOff.state(offering: updates.line),
               !coordinator.meetings.isRecording {
                Button(line.title) {
                    updateHandOff.click(offering: updates.line)
                }
                .disabled(!line.isEnabled)
            }

            // back from settings (reversing part of ADR 0030, recorded in
            // 0034): the mac-standard home for a menu bar app's identity.
            Button("about Andrew Dictate") {
                coordinator.openAbout()
            }

            // what a friend sends instead of a story: the last fifty
            // presses and how each ended, never a word of what was said.
            Button("copy diagnostics") {
                coordinator.copyDiagnostics()
            }

            Button("quit Andrew Dictate") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(
                nsImage: MenuBarBrandIcon.image(
                    for: coordinator.state,
                    needsAttention: coordinator.needsAttention,
                    isRecordingMeeting: coordinator.meetings.isRecording
                )
            )
            .accessibilityLabel(menuBarLabel)
            .task {
                lifecycleDelegate.onReopen = { [weak coordinator] in
                    coordinator?.handleReopen()
                }
                lifecycleDelegate.onTerminate = { [weak coordinator] in
                    coordinator?.prepareToQuit() ?? .terminateNow
                }
                // busy is anything but idle: loading the model, a take, a
                // meeting. the check waits for the next tick; a click on
                // the line is refused.
                let isBusy = { [weak coordinator] in
                    guard let coordinator else {
                        return true
                    }
                    return coordinator.state != .idle
                        || coordinator.meetings.isRecording
                }
                updates.start(isBusy: isBusy)
                updateHandOff.isBusy = isBusy
            }
        }

        // the system settings scene, not a hand-rolled window: pane chrome,
        // per-pane window title, and dimmed traffic lights come free, and
        // they're what the HIG asks of a settings window (ADR 0036).
        Settings {
            SettingsView(
                coordinator: coordinator,
                meetingsLoader: {
                    MeetingTranscriptFile.listAll(
                        in: coordinator.settings.meetingsFolder)
                }
            )
        }
        .windowResizability(.contentSize)
    }
}
