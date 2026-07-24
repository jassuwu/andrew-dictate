import AppKit
import SwiftUI

@MainActor
struct HUDGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        // SwiftUI clipShape cannot clip a behind-window backdrop — WindowServer
        // composites from the view frame. A stretchable capsule maskImage is the
        // supported way to shape the blur region.
        view.maskImage = Self.capsuleMask(radius: 22)
        return view
    }

    private static func capsuleMask(radius: CGFloat) -> NSImage {
        let side = radius * 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func updateNSView(
        _ nsView: NSVisualEffectView,
        context: Context
    ) {}
}
