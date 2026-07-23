import AppKit
import SwiftUI

@MainActor
final class HUDPanel: NSPanel {
    private static let contentSize = NSSize(width: 220, height: 58)
    private static let bottomOffset: CGFloat = 80

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(viewModel: HUDViewModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: HUDView(viewModel: viewModel))
        hostingView.frame = NSRect(origin: .zero, size: Self.contentSize)
        contentView = hostingView
    }

    func present() {
        positionOnPointerScreen()
        invalidateShadow()
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    private func positionOnPointerScreen() {
        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(pointerLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let screen else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + Self.bottomOffset
        )
        setFrameOrigin(origin)
    }
}
