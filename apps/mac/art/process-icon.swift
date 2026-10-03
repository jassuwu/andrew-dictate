import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// andrew dictate — icon pipeline from the two drawings: logo.svg, and
// logo-small.svg, its cut for 32 px and under. each draws the whole tile, edge
// to edge and corners included, so all this does is stand a drawing on a
// canvas. emits EXACT-pixel PNGs via CGBitmapContext (NSImage.lockFocus
// renders at screen scale and silently doubles dimensions, which corrupts the
// asset catalog and degrades NSApp.applicationIconImage).

let args = CommandLine.arguments
let artDir = args.count > 1 ? args[1] : "."
let outDir = args.count > 2 ? args[2] : "."

func drawing(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOfFile: "\(artDir)/\(name)") else { fatalError("cannot load \(name)") }
    return image
}
let logo = drawing("logo.svg")
let small = drawing("logo-small.svg")

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("dest fail \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize fail \(path)") }
}

func renderIcon(_ drawing: NSImage, pixels: Int, insetFraction: CGFloat) -> CGImage {
    let s = CGFloat(pixels)
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("ctx fail") }
    let inset = s * insetFraction
    let content = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    // the svg is drawn as vectors at this size, never scaled up from pixels.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawing.draw(in: content)
    NSGraphicsContext.restoreGraphicsState()
    guard let out = ctx.makeImage() else { fatalError("makeImage fail") }
    return out
}

// the app icon stands on apple's grid — an 824 pt body in a 1024 pt canvas —
// so it is the same height as its neighbours in /Applications, in spotlight and
// in the microphone alert. everywhere else the badge gets no canvas of its own,
// so it keeps its hairline inset and stays full-bleed.
let appIconInset: CGFloat = 100.0 / 1024.0
let badgeInset: CGFloat = 0.02

for size in [16, 32] {
    writePNG(renderIcon(small, pixels: size, insetFraction: appIconInset), to: "\(outDir)/icon_\(size).png")
}
for size in [64, 128, 256, 512, 1024] {
    writePNG(renderIcon(logo, pixels: size, insetFraction: appIconInset), to: "\(outDir)/icon_\(size).png")
}
// menu bar sizes (full-color badge, 1x/2x)
for size in [18, 36] {
    writePNG(renderIcon(small, pixels: size, insetFraction: badgeInset), to: "\(outDir)/menubar_\(size).png")
}
// the badge alone: what about and onboarding show, what the site serves and
// what the og image composites
for size in [512, 1024] {
    writePNG(renderIcon(logo, pixels: size, insetFraction: badgeInset), to: "\(outDir)/badge_\(size).png")
}
// a browser tab is 16 pt, so the favicon is the small cut
for size in [32, 256] {
    writePNG(renderIcon(small, pixels: size, insetFraction: badgeInset), to: "\(outDir)/favicon_\(size).png")
}
print("icons rendered (exact pixels)")
