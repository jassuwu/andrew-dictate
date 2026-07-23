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
            Text(coordinator.state.rawValue)
                .foregroundStyle(.secondary)
                .disabled(true)

            Divider()

            Button("quit Andrew Dictate") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
