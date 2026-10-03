import AppKit

// og image compositor: the one lockup. dark bg, the badge (from
// badge_1024.png) beside the name, the pitch in large type, the facts line
// under it, and the lamp lit at the bottom centre, where the app puts it.
// the readme's banner is this same picture.
// rendered at 2x (2400x1260) because that is what the site ships, into an
// explicit bitmap so a retina display cannot double it again.
// the type roles match the app (ADR 0037): paper for the name and the pitch,
// machine (Ioskeley Mono) for the facts line.
let art = FileManager.default.currentDirectoryPath
// the badge alone, never icon_1024.png: that one carries apple's icon-grid
// padding (process-icon.swift), and a poster is not an icon slot.
guard let badge = NSImage(contentsOfFile: art + "/badge_1024.png") else { fatalError("no badge_1024") }

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

let goldPale = NSColor(srgbRed: 0xF9/255, green: 0xE9/255, blue: 0xA8/255, alpha: 1)
let gold = NSColor(srgbRed: 0xE5/255, green: 0xBE/255, blue: 0x62/255, alpha: 1)
let goldDeep = NSColor(srgbRed: 0x9E/255, green: 0x75/255, blue: 0x27/255, alpha: 1)

let left = 84 * S

// the badge and the name, as the site's first lines have them
badge.draw(in: NSRect(x: left, y: 452 * S, width: 96 * S, height: 96 * S))

NSAttributedString(string: "andrew dictate", attributes: [
    .font: NSFont.systemFont(ofSize: 40 * S, weight: .semibold),
    .foregroundColor: goldPale, .kern: -0.8 * S,
]).draw(at: NSPoint(x: left + 122 * S, y: 498 * S))

NSAttributedString(string: "escape the keyboard.", attributes: [
    .font: NSFont.systemFont(ofSize: 25 * S, weight: .regular),
    .foregroundColor: gold,
]).draw(at: NSPoint(x: left + 124 * S, y: 460 * S))

// the pitch, in two lines
let pitch: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 92 * S, weight: .semibold),
    .foregroundColor: goldPale, .kern: -3.4 * S,
]
NSAttributedString(string: "dictation for talking", attributes: pitch)
    .draw(at: NSPoint(x: left - 4 * S, y: 296 * S))
NSAttributedString(string: "to your agents.", attributes: pitch)
    .draw(at: NSPoint(x: left - 4 * S, y: 196 * S))

NSAttributedString(string: "dictation · meetings · free · fast · local", attributes: [
    .font: mono(27 * S),
    .foregroundColor: gold,
]).draw(at: NSPoint(x: left, y: 128 * S))

// the lamp, lit: the tube the hud draws, with the light it spills
let lampY = 58 * S, lampHalf = 110 * S, lampThickness = 7 * S
let tube = NSBezierPath()
tube.move(to: NSPoint(x: CGFloat(W) / 2 - lampHalf, y: lampY))
tube.line(to: NSPoint(x: CGFloat(W) / 2 + lampHalf, y: lampY))
tube.lineCapStyle = .round

NSGraphicsContext.saveGraphicsState()
let halo = NSShadow()
halo.shadowColor = gold.withAlphaComponent(0.75)
halo.shadowBlurRadius = 26 * S
halo.set()
gold.withAlphaComponent(0.9).setStroke()
tube.lineWidth = lampThickness
tube.stroke()
NSGraphicsContext.restoreGraphicsState()

goldDeep.blended(withFraction: 0.72, of: goldPale)!.setStroke()
tube.lineWidth = lampThickness
tube.stroke()

let rim = NSBezierPath()
rim.move(to: NSPoint(x: CGFloat(W) / 2 - lampHalf, y: lampY + lampThickness / 2 - 1.2 * S))
rim.line(to: NSPoint(x: CGFloat(W) / 2 + lampHalf, y: lampY + lampThickness / 2 - 1.2 * S))
rim.lineCapStyle = .round
rim.lineWidth = 1.3 * S
goldPale.setStroke()
rim.stroke()

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
try! png.write(to: URL(fileURLWithPath: art + "/og.png"))
print("og composed")
