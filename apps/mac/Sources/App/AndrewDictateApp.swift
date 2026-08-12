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
            Text(coordinator.state.displayName)
                .foregroundStyle(.secondary)
                .disabled(true)

            Button("copy last transcript") {
                coordinator.copyLastTranscript()
            }
            .disabled(coordinator.lastTranscript == nil)

            Divider()

            Button("settings…") {
                coordinator.openSettings()
            }

            #if DEBUG
            Button("copy timings") {
                coordinator.copyTimings()
            }
            #endif

            // the way back. ships in release: a user who skipped setup, or
            // whose permissions were withdrawn, had no route but deleting
            // their defaults.
            Button(
                coordinator.needsPermissionAttention
                    ? "finish setup"
                    : "run onboarding again"
            ) {
                coordinator.runOnboardingAgain()
            }

            Button("about Andrew Dictate") {
                coordinator.openAbout()
            }

            Divider()

            Button("quit Andrew Dictate") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(
                nsImage: MenuBarBrandIcon.image(
                    for: coordinator.state,
                    needsAttention: coordinator.needsPermissionAttention
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
    }
}
