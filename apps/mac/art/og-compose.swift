import AppKit

// og image compositor: dark bg + the badge (from icon_1024.png) + type.
// rendered at 2x (2400x1260) because that is what the site ships, into an
// explicit bitmap so a retina display cannot double it again.
// the type roles match the app (ADR 0037): paper for the name, machine
// (Ioskeley Mono) for the tagline and the facts line.
let art = FileManager.default.currentDirectoryPath
guard let badge = NSImage(contentsOfFile: art + "/icon_1024.png") else { fatalError("no icon_1024") }

let monoURL = URL(fileURLWithPath: art + "/../Sources/Resources/Fonts/IoskeleyMono-Regular.ttf")
CTFontManagerRegisterFontsForURL(monoURL as CFURL, .process, nil)
func mono(_ size: CGFloat) -> NSFont {
    NSFont(name: "Ioskeley-Mono", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

let S: CGFloat = 2
let W = Int(1200 * S), H = Int(630 * S)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no bitmap") }
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

NSColor(srgbRed: 0x0C/255, green: 0x0C/255, blue: 0x0E/255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

badge.draw(in: NSRect(x: 80 * S, y: 95 * S, width: 440 * S, height: 440 * S))

let goldPale = NSColor(srgbRed: 0xF9/255, green: 0xE9/255, blue: 0xA8/255, alpha: 1)
let gold = NSColor(srgbRed: 0xE5/255, green: 0xBE/255, blue: 0x62/255, alpha: 1)

let name = NSAttributedString(string: "andrew dictate", attributes: [
    .font: NSFont.systemFont(ofSize: 84 * S, weight: .semibold),
    .foregroundColor: goldPale, .kern: -1.5 * S])
name.draw(at: NSPoint(x: 580 * S, y: 330 * S))

let tag = NSAttributedString(string: "escape the keyboard.", attributes: [
    .font: mono(36 * S),
    .foregroundColor: gold])
tag.draw(at: NSPoint(x: 584 * S, y: 268 * S))

// the facts line ends at the same margin the badge starts on. shrink until it fits.
let subX = 584 * S, rightMargin = 80 * S
var subSize = 25 * S
var sub: NSAttributedString
repeat {
    sub = NSAttributedString(string: "dictation · meetings · free · fully local", attributes: [
        .font: mono(subSize),
        .foregroundColor: goldPale.withAlphaComponent(0.5)])
    subSize -= 1
} while sub.size().width > CGFloat(W) - subX - rightMargin
sub.draw(at: NSPoint(x: subX, y: 96 * S))

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
try! png.write(to: URL(fileURLWithPath: art + "/og.png"))
print("og composed")
