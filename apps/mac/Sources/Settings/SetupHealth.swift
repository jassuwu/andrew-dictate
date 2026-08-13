import Foundation

struct SetupIssue: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
}

/// what settings should admit is wrong. it reports the problem and hands the
/// user back to onboarding to fix it — onboarding already owns the grant flow,
/// and a second implementation of it is exactly the drift being repaired here.
enum SetupHealth {
    static func issues(
        permissions: PermissionSnapshot,
        speechModelFailed: Bool
    ) -> [SetupIssue] {
        var issues: [SetupIssue] = []

        if !permissions.microphoneGranted {
            issues.append(
                SetupIssue(
                    id: "microphone",
                    title: "microphone",
                    detail: "andrew can't hear you until macOS allows it."
                )
            )
        }

        if !permissions.accessibilityGranted {
            issues.append(
                SetupIssue(
                    id: "accessibility",
                    title: "accessibility",
                    detail: "the dictation key and pasting both need it."
                )
            )
        }

        if speechModelFailed {
            issues.append(
                SetupIssue(
                    id: "speech-model",
                    title: "speech model",
                    detail: "the download didn't finish."
                )
            )
        }

        return issues
    }
}
