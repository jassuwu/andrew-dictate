import SwiftUI

@main
struct AndrewDictateApp: App {
    var body: some Scene {
        MenuBarExtra("Andrew Dictate", systemImage: "waveform") {
            Button("quit Andrew Dictate") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
