import AppKit
import QuartzCore
import SwiftUI

/// a click on a window that is not key is, by default, spent making it key.
/// this one never becomes key, so the click would be spent on nothing: the
/// pill's button takes the first one.
private final class HUDHostingView: NSHostingView<HUDView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class HUDPanel: NSPanel {
    private static let bottomOffset: CGFloat = 80
    /// often enough that the pill takes the mouse before a hand on its way
    /// to the button gets there.
    private static let pointerWatchInterval: TimeInterval = 1.0 / 30.0
    private var hudHostingView: NSHostingView<HUDView>?
    private var visibilityGeneration: UInt64 = 0
    /// the pill with a button that is up, by its size: the panel takes the
    /// mouse over it and nowhere else.
    private var reachablePill: CGSize?
    private var pointerWatch: Timer?
    private var pointerIsOverPill = false
    /// told when the pointer goes over a pill with a button, and when it
    /// leaves: its countdown stops while a hand is on it.
    var onPointerOverPill: ((Bool) -> Void)?

    override var canBecomeKey: Bool {
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

        let hostingView = HUDHostingView(
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
        makePillReachable(nil)
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        guard isVisible else {
            alphaValue = 1
            orderOut(nil)
            return
        }

        // every pill leaves the way it arrived. the old non-fast path cut to
        // nothing between two frames, which read as the message being eaten.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fast ? 0.12 : 0.16
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

    /// a pill with a button has to take a click, and the panel ignores the
    /// mouse: the stage around the pill is invisible, and a click meant for
    /// the app under it must reach that app. so while a pill has a button
    /// the panel follows the pointer, and takes the mouse only while it is
    /// over the pill itself. nil goes back to click-through. never key
    /// either way, so a click on the button leaves the keyboard where it
    /// was.
    func makePillReachable(_ pillSize: CGSize?) {
        reachablePill = pillSize
        guard pillSize != nil else {
            pointerWatch?.invalidate()
            pointerWatch = nil
            ignoresMouseEvents = true
            notePointer(overPill: false)
            return
        }
        if pointerWatch == nil {
            let timer = Timer(
                timeInterval: Self.pointerWatchInterval,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.followPointer()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerWatch = timer
        }
        followPointer()
    }

    /// the pill sits in the middle of the stage, which is the panel.
    private func followPointer() {
        guard let pillSize = reachablePill, isVisible else {
            ignoresMouseEvents = true
            notePointer(overPill: false)
            return
        }
        let pill = NSRect(
            x: frame.midX - pillSize.width / 2,
            y: frame.midY - pillSize.height / 2,
            width: pillSize.width,
            height: pillSize.height
        )
        let over = NSMouseInRect(NSEvent.mouseLocation, pill, false)
        if ignoresMouseEvents == over {
            ignoresMouseEvents = !over
        }
        notePointer(overPill: over)
    }

    private func notePointer(overPill over: Bool) {
        guard over != pointerIsOverPill else {
            return
        }
        pointerIsOverPill = over
        onPointerOverPill?(over)
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
