import Foundation

/// What this build is allowed to do.
///
/// Keyed off `AppIdentity` rather than `#if DEBUG` for two reasons: it is
/// testable, and the split that matters is now about *identity* rather than
/// compilation — a debug build is a separate app with separate data (ADR 0027),
/// which is exactly what makes destructive shortcuts safe in it.
///
/// The rule for adding one: a capability is development-only when using it on
/// real data would be a mistake, not when it is merely unpolished. Anything a
/// user would genuinely want ships in both.
struct Capabilities: Equatable, Sendable {
    /// Remove what the app has kept, item by item. **Both builds.** A user who
    /// wants to leave should not have to hunt through Application Support, and
    /// "it leaves no traces" is only true if the app can prove it.
    let canUninstall: Bool

    /// Wipe everything and relaunch, without the confirmation a real removal
    /// deserves. **Development only** — it exists to make onboarding testable
    /// on the twentieth run, and on real data it would be a foot-gun with no
    /// safety catch.
    let canResetInPlace: Bool

    /// Copy the latency distribution. **Both builds** (ADR 0025): a number a
    /// reader can generate themselves is the whole point of the speed claim.
    let canCopyTimings: Bool

    /// Say which build this is, in the menu. **Development only** — the
    /// released app has no reason to talk about itself.
    let announcesItself: Bool

    /// Record every raw/cleaned pair to the lab log and offer the lab and
    /// pipeline viewers. **Development only.** The lab exists to develop the
    /// cleaner; a user's record of what cleanup changed is the archive, which
    /// they opted into. Keeping a transcript log the "keep what you dictate"
    /// toggle doesn't govern would make that toggle a lie.
    let keepsCleanupLab: Bool

    static let release = Capabilities(
        canUninstall: true,
        canResetInPlace: false,
        canCopyTimings: true,
        announcesItself: false,
        keepsCleanupLab: false
    )

    static let development = Capabilities(
        canUninstall: true,
        canResetInPlace: true,
        canCopyTimings: true,
        announcesItself: true,
        keepsCleanupLab: true
    )

    static var current: Capabilities {
        AppIdentity.isReleaseBuild ? .release : .development
    }
}
