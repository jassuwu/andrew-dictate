import AVFoundation
import AppKit
import ApplicationServices

/// the live reads. every call asks the system — nothing here is cached,
/// because a cache is exactly the bug: granted once, assumed forever.
@MainActor
enum SystemPermissions {
    /// macOS posts this on the distributed centre when the accessibility
    /// trust table changes. long-standing, but not formally documented, so it
    /// is only ever a bonus path: the launch, reopen and wake checks stand on
    /// their own if it never fires.
    static let accessibilityChanged = Notification.Name(
        "com.apple.accessibility.api"
    )

    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphoneGranted: AVCaptureDevice.authorizationStatus(
                for: .audio
            ) == .authorized,
            accessibilityGranted: AXIsProcessTrusted()
        )
    }
}
