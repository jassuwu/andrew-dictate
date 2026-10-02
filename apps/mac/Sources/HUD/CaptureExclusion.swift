import AppKit

/// a window left out of every screen capture: a share, a recording, a
/// screenshot. measured on macOS 27 (wayfinder 018, measurement 04):
/// `sharingType = .none` keeps a window or a non-activating panel out of
/// `screencapture`, ScreenCaptureKit's screenshots and live streams (the
/// path a call app shares a screen through), and single-window capture, while
/// it stays on screen for you. the menu bar icon cannot be hidden this way.
enum CaptureExclusion {
    #if DEBUG
    /// development only, compiled out of release: `defaults write
    /// gg.jass.dictate.dev hudVisibleToCapture -bool true`, then a relaunch,
    /// leaves the hud and the live transcript in every capture, so a
    /// screenshot can show what they look like. read once.
    static let isSetAsideForDevelopment = UserDefaults.standard.bool(
        forKey: "hudVisibleToCapture"
    )
    #endif

    static func sharingType(hidden: Bool) -> NSWindow.SharingType {
        #if DEBUG
        if isSetAsideForDevelopment {
            return .readOnly
        }
        #endif
        return hidden ? .none : .readOnly
    }
}
