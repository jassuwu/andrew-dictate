import FluidAudio
import Foundation

/// where everything lives. the recordings are spoken history and never leave
/// this machine, so they sit beside the dev build's archive, not in the repo.
enum Folders {
    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// the dev build's own folder, the same one AppIdentity names.
    static var devSupport: URL {
        applicationSupport.appendingPathComponent("Andrew Dictate Dev", isDirectory: true)
    }

    static var history: URL {
        devSupport.appendingPathComponent("dictations.jsonl", isDirectory: false)
    }

    static var recordings: URL {
        devSupport.appendingPathComponent("fidelity", isDirectory: true)
    }

    static var prompts: URL {
        recordings.appendingPathComponent("prompts.json", isDirectory: false)
    }

    static func passage(_ number: Int) -> URL {
        recordings.appendingPathComponent(String(format: "passage-%02d.wav", number), isDirectory: false)
    }

    /// the speech models FluidAudio already keeps for the app. the tool reads
    /// them where they are and never downloads.
    static var parakeetV2: URL {
        AsrModels.defaultCacheDirectory(for: .v2)
    }

    static func makeRecordings() throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }
}
