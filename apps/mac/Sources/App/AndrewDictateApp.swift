import AppKit
import SwiftUI

/// a menu-bar app is never "opened" twice — double-clicking it in
/// /Applications sends a reopen to the instance already running. that is the
/// user coming back to us, and the moment to re-verify what we're allowed to do.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        onReopen?()
        return true
    }
}

@main
@MainActor
struct AndrewDictateApp: App {
    @StateObject private var coordinator = DictationCoordinator()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate

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
                Text(
                    "recording \(coordinator.meetingAppName) · "
                        + coordinator.meetings.elapsed.runningClock
                )
                .foregroundStyle(.secondary)
                .disabled(true)

                Button("stop recording \(coordinator.meetingAppName)") {
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
                .disabled(coordinator.lastTranscript == nil)

                // nothing starts a recording but the user, and the user
                // names the app (ADR 0023, 0040). meeting apps first.
                Menu("record a meeting") {
                    let ranked = MeetingApps.rank(MeetingApps.running())
                    ForEach(ranked.meeting) { app in
                        Button(MeetingApps.displayName(app)) {
                            coordinator.startMeeting(app)
                        }
                    }
                    if !ranked.meeting.isEmpty, !ranked.other.isEmpty {
                        Divider()
                    }
                    ForEach(ranked.other) { app in
                        Button(MeetingApps.displayName(app)) {
                            coordinator.startMeeting(app)
                        }
                    }
                    if ranked.meeting.isEmpty, ranked.other.isEmpty {
                        Text("nothing is running that could be recorded")
                            .disabled(true)
                    }
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
            if coordinator.needsPermissionAttention {
                Button("finish setup") {
                    coordinator.runOnboardingAgain()
                }
            }

            if Capabilities.current.canResetInPlace {
                Button("reset & relaunch (dev)") {
                    coordinator.resetInPlaceForDevelopment()
                }
            }

            Divider()

            // back from settings (reversing part of ADR 0030, recorded in
            // 0034): the mac-standard home for a menu bar app's identity.
            Button("about Andrew Dictate") {
                coordinator.openAbout()
            }

            Button("quit Andrew Dictate") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(
                nsImage: MenuBarBrandIcon.image(
                    for: coordinator.state,
                    needsAttention: coordinator.needsPermissionAttention,
                    isRecordingMeeting: coordinator.meetings.isRecording
                )
            )
            .accessibilityLabel(
                coordinator.needsPermissionAttention
                    ? "Andrew Dictate — permission needed"
                    : "Andrew Dictate"
            )
            .task {
                lifecycleDelegate.onReopen = { [weak coordinator] in
                    coordinator?.handleReopen()
                }
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
