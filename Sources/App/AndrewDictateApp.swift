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

            PreRollMenuToggle(settings: coordinator.settings)

            Divider()

            Button("quit Andrew Dictate") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

private struct PreRollMenuToggle: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Toggle("pre-roll", isOn: $settings.preRollEnabled)
    }
}
