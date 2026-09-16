import Foundation
import ServiceManagement

/// The login item, in one place. Two surfaces write this one system state now
/// — setup offers it once, the general tab is the off switch — and macOS's
/// four answers need one set of words between them, not two that drift.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?
    /// `.notFound` means macOS has no registration to make for this bundle. A
    /// row you cannot need is a row you have to wonder about, so setup hides
    /// it rather than offering a switch that cannot move.
    @Published private(set) var isAvailable = true
    /// Nothing has been asked yet: a fresh install, or someone who switched
    /// it off. Indistinguishable, so setup offers it on either way.
    @Published private(set) var isUnregistered = true

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            message = nil
            isAvailable = true
            isUnregistered = false
        case .requiresApproval:
            isEnabled = true
            message = "approval is required in system settings"
            isAvailable = true
            isUnregistered = false
        case .notFound:
            isEnabled = false
            message = "launch at login is unavailable"
            isAvailable = false
            isUnregistered = false
        case .notRegistered:
            isEnabled = false
            message = nil
            isAvailable = true
            isUnregistered = true
        @unknown default:
            isEnabled = false
            message = nil
            isAvailable = true
            isUnregistered = true
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            message = "couldn’t update launch at login"
        }
    }
}
