import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class HotkeyMonitor {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var isFunctionHeld = false
    private var isCurrentHoldCancelled = false

    init() {
        requestAccessibilityPermission()
        installMonitors()
    }

    private func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func installMonitors() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] _ in
                self?.handleKeyDown()
            }
        ) {
            monitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                self?.handleKeyDown()
                return event
            }
        ) {
            monitors.append(monitor)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let functionIsPressed = event.modifierFlags.contains(.function)
        guard functionIsPressed != isFunctionHeld else {
            return
        }

        isFunctionHeld = functionIsPressed

        if functionIsPressed {
            isCurrentHoldCancelled = false
            onBegin?()
        } else if isCurrentHoldCancelled {
            isCurrentHoldCancelled = false
        } else {
            onEnd?()
        }
    }

    private func handleKeyDown() {
        guard isFunctionHeld, !isCurrentHoldCancelled else {
            return
        }

        isCurrentHoldCancelled = true
        onCancel?()
    }
}
