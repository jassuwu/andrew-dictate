import AppKit
import SwiftUI

/// the window the live view lives in: a floating glass panel, toggled from the
/// menu and remembered (SPEC §11).
///
/// it is a panel rather than a window because a meeting is something you are
/// already doing — it floats over zoom, joins every space, and does not
/// activate the app when you click it, so glancing at the transcript never
/// takes focus off the call. it is `.titled` and `.closable` anyway, because
/// the close button is the exit people reach for and a panel without one is a
/// thing you have to go and find the menu to get rid of.
///
/// closing is remembered, not just hiding. someone who shut this panel does
/// not want it back at the next meeting, and someone who left it open does —
/// that is the whole of what the preference stores.
@MainActor
final class LiveTranscriptPanel: NSObject, NSWindowDelegate {
    /// Whether the panel was open when the last meeting ended, so the
    /// coordinator can put it back without asking.
    static var wasOpenLastTime: Bool {
        UserDefaults.standard.bool(forKey: openDefaultsKey)
    }

    static let openDefaultsKey = "AndrewDictate.liveTranscriptOpen"

    private static let autosaveName = "live-transcript"
    private static let defaultSize = NSSize(width: 380, height: 280)
    /// far enough off the corner that it is clearly a floating thing and not
    /// part of the screen edge.
    private static let screenMargin: CGFloat = 24

    /// Told on every show and hide, including the close button — the menu's
    /// "hide live transcript" must not outlive the panel.
    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: NSPanel
    private let defaults: UserDefaults

    init(
        model: LiveTranscriptModel,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
                .utilityWindow,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "live transcript"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        // a floating transcript that vanishes the moment you click back into
        // the meeting is not a transcript.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 280, height: 160)
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: LiveTranscriptView(model: model)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setContentSize(Self.defaultSize)

        // the saved frame wins; the corner is only where it starts life.
        if !panel.setFrameUsingName(Self.autosaveName) {
            moveToDefaultCorner()
        }
        panel.setFrameAutosaveName(Self.autosaveName)
    }

    var isShown: Bool {
        panel.isVisible
    }

    func show() {
        // ordered front *regardless*: this app has no dock icon and is usually
        // inactive, so an ordinary orderFront would put the panel behind the
        // meeting it is transcribing.
        panel.orderFrontRegardless()
        remember(true)
        onVisibilityChange?(true)
    }

    func hide() {
        panel.orderOut(nil)
        remember(false)
        onVisibilityChange?(false)
    }

    /// The meeting ended: the panel goes, the preference stays. Whoever left
    /// it open gets it back at the next meeting.
    func dismissKeepingPreference() {
        panel.delegate = nil
        panel.orderOut(nil)
        panel.delegate = self
        onVisibilityChange?(false)
    }

    func toggle() {
        if isShown {
            hide()
        } else {
            show()
        }
    }

    // MARK: - NSWindowDelegate

    /// the close button is a way of saying "not this meeting either", and it
    /// has to be recorded the same as choosing hide from the menu.
    func windowWillClose(_ notification: Notification) {
        remember(false)
        onVisibilityChange?(false)
    }

    private func remember(_ isOpen: Bool) {
        defaults.set(isOpen, forKey: Self.openDefaultsKey)
    }

    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - size.width - Self.screenMargin,
                y: visible.minY + Self.screenMargin
            )
        )
    }
}
