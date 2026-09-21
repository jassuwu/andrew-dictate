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
        // no window shadow: the glass draws its own edge, and a shadow
        // would outline the invisible stage
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(
            rootView: HUDView(viewModel: viewModel)
        )
        // Never ask the hosting view to measure itself. The layout engine is the
        // sole source of truth for both this view and the panel frame.
        hostingView.sizingOptions = []
        let size = HUDLayoutEngine.stageSize(screenWidth: 1_440)
        hostingView.wantsLayer = true
        hostingView.autoresizingMask = [.width, .height]
        hudHostingView = hostingView
        contentView = hostingView
        setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    func present() {
        visibilityGeneration &+= 1
        alphaValue = 1
        fitStage()
        positionOnPointerScreen()
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

    /// the window never morphs any more: it is a transparent, click-through
    /// stage sized for the widest pill on this screen, and the glass inside
    /// it does the shape-changing. sized on every present, because the
    /// pointer may have moved to another screen.
    private func fitStage() {
        let size = HUDLayoutEngine.stageSize(
            screenWidth: presentationScreenWidth()
        )
        guard frame.size != size else {
            return
        }
        setContentSize(size)
        hudHostingView?.frame = NSRect(origin: .zero, size: size)
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
