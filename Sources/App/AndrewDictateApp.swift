import SwiftUI

@main
@MainActor
struct AndrewDictateApp: App {
    @StateObject private var coordinator = DictationCoordinator()

    var body: some Scene {
        MenuBarExtra(
            "Andrew Dictate",
            systemImage: coordinator.state.systemImage
        ) {
            Text(coordinator.state.displayName)
                .foregroundStyle(.secondary)
                .disabled(true)

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
        }
    }
}
