import AppKit
import SwiftUI

@main
@MainActor
struct AndrewDictateApp: App {
    @StateObject private var coordinator = DictationCoordinator()

    var body: some Scene {
        MenuBarExtra {
            Text(coordinator.state.displayName)
                .foregroundStyle(.secondary)
                .disabled(true)

            Button("copy last transcript") {
                coordinator.copyLastTranscript()
            }
            .disabled(coordinator.lastTranscript == nil)

            Button("copy last answer") {
                coordinator.copyLastAnswer()
            }
            .disabled(coordinator.lastAnswer == nil)

            Divider()

            Button("settings…") {
                coordinator.openSettings()
            }

            #if DEBUG
            Button("copy timings") {
                coordinator.copyTimings()
            }

            Button("run onboarding again") {
                coordinator.runOnboardingAgain()
            }
            #endif

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
                    for: coordinator.state
                )
            )
            .accessibilityLabel("Andrew Dictate")
        }
    }
}
