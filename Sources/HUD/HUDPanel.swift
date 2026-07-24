import AppKit
import SwiftUI

@MainActor
final class HUDPanel: NSPanel {
    private static let bottomOffset: CGFloat = 80

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(viewModel: HUDViewModel) {
        super.init(
            contentRect: .zero,
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
        // fixed size, no forced layout: measuring the hosting view here starts a
        // nested AttributeGraph update, which aborts if a SwiftUI update is already
        // in flight. the capsule is constant-size by design (HUDView.panelSize).
        hostingView.sizingOptions = []
        let size = NSSize(
            width: HUDView.panelSize.width,
            height: HUDView.panelSize.height
        )
        // the window IS the capsule: behind-window blur composites over the whole
        // window rect regardless of SwiftUI clipping, so the only reliable shape
        // is the window itself — exact capsule size, layer-rounded and masked.
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = size.height / 2
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
        setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
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
