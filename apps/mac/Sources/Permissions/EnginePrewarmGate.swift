import Foundation

/// whether a launch is allowed to fetch a speech model.
///
/// the same shape as `SetupGate` next door, asked about bytes instead of
/// grants: the ticks on the first card say which jobs exist, and a launch that
/// ignores them downloads ~460 mb for a job the user declined — the one thing
/// the consent screen promises will not happen. a pure function, so the
/// promise can be argued with in tests rather than by deleting model folders.
enum EnginePrewarmGate {
    static func shouldPrewarmAtLaunch(
        onboardingDismissed: Bool,
        dictationWanted: Bool
    ) -> Bool {
        // before setup has been through, nothing downloads at all: the click
        // is the moment the downloads start (SPEC §5).
        guard onboardingDismissed else {
            return false
        }
        return dictationWanted
    }
}
