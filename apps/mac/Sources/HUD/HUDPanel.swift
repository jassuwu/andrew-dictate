import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class HUDPanel: NSPanel {
    private static let bottomOffset: CGFloat = 80
    private var hudHostingView: NSHostingView<HUDView>?
    private var visibilityGeneration: UInt64 = 0

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

        let hostingView = NSHostingView(
            rootView: HUDView(viewModel: viewModel)
        )
        // Never ask the hosting view to measure itself. The layout engine is the
        // sole source of truth for both this view and the panel frame.
        hostingView.sizingOptions = []
        let size = HUDLayoutEngine.minimumSize
        // the window IS the capsule: behind-window blur composites over the whole
        // window rect regardless of SwiftUI clipping, so the only reliable shape
        // is the window itself — exact HUD size, layer-rounded and masked.
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = min(size.height, 44) / 2
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.autoresizingMask = [.width, .height]
        hudHostingView = hostingView
        contentView = hostingView
        setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    func present() {
        visibilityGeneration &+= 1
        alphaValue = 1
        positionOnPointerScreen()
        invalidateShadow()
        orderFrontRegardless()
    }

    func dismiss(fast: Bool = false) {
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        guard fast, isVisible else {
            alphaValue = 1
            orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(
                name: .easeOut
            )
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.visibilityGeneration == generation else {
                    return
                }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        }
    }

    func presentationScreenWidth() -> CGFloat {
        pointerScreen()?.frame.width
            ?? NSScreen.main?.frame.width
            ?? 1_440
    }

    func morph(to size: CGSize, animated: Bool) {
        let targetFrame = NSRect(
            x: frame.midX - size.width / 2,
            y: frame.minY,
            width: size.width,
            height: size.height
        )
        let hostingFrame = NSRect(origin: .zero, size: size)
        let cornerRadius = min(size.height, 44) / 2

        guard animated else {
            setFrame(targetFrame, display: true)
            hudHostingView?.frame = hostingFrame
            hudHostingView?.layer?.cornerRadius = cornerRadius
            invalidateShadow()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2,
                1.3,
                0.3,
                1
            )
            context.allowsImplicitAnimation = true
            animator().setFrame(targetFrame, display: true)
            hudHostingView?.animator().frame = hostingFrame
            hudHostingView?.layer?.cornerRadius = cornerRadius
        }
        invalidateShadow()
    }

    private func positionOnPointerScreen() {
        guard let screen = pointerScreen() else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + Self.bottomOffset
        )
        setFrameOrigin(origin)
    }

    private func pointerScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(pointerLocation, $0.frame, false)
        } ?? NSScreen.main
    }
}
