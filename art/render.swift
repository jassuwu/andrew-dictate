import AppKit
import CoreGraphics

// andrew dictate brand renderer — icon + og image
let bg = NSColor(srgbRed: 0x1B/255.0, green: 0x1B/255.0, blue: 0x1F/255.0, alpha: 1)
let bgTop = NSColor(srgbRed: 0x24/255.0, green: 0x24/255.0, blue: 0x2A/255.0, alpha: 1)
let cream = NSColor(srgbRed: 0xEF/255.0, green: 0xEA/255.0, blue: 0xE0/255.0, alpha: 1)
let accent = NSColor(srgbRed: 0xE4/255.0, green: 0x59/255.0, blue: 0x3B/255.0, alpha: 1)
let heights: [CGFloat] = [0.34, 0.62, 0.86, 0.50, 0.28]
let accentIndex = 1

func drawBars(in rect: CGRect, barWidthRatio: CGFloat = 0.14, gapRatio: CGFloat = 0.095) {
    let n = CGFloat(heights.count)
    let barW = rect.width * barWidthRatio
    let gap = rect.width * gapRatio
    let totalW = n * barW + (n - 1) * gap
    var x = rect.midX - totalW / 2
    for (i, h) in heights.enumerated() {
        let barH = rect.height * h
        let barRect = CGRect(x: x, y: rect.midY - barH / 2, width: barW, height: barH)
        let path = NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2)
        (i == accentIndex ? accent : cream).setFill()
        path.fill()
        x += barW + gap
    }
}

func renderIcon(size: Int, to url: URL) {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    // squircle-ish full-bleed rounded rect (macOS masks corners itself at display, but bake shape for dock fidelity)
    let inset = s * 0.098
    let shape = NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset), xRadius: (s - 2*inset) * 0.226, yRadius: (s - 2*inset) * 0.226)
    let gradient = NSGradient(starting: bgTop, ending: bg)!
    shape.setClip()
    gradient.draw(in: CGRect(x: 0, y: 0, width: s, height: s), angle: -90)
    // bars occupy central 56%
    let content = CGRect(x: s * 0.22, y: s * 0.22, width: s * 0.56, height: s * 0.56)
    drawBars(in: content)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
    try! png.write(to: url)
}

func renderOG(to url: URL) {
    let w: CGFloat = 1200, h: CGFloat = 630
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    bg.setFill()
    CGRect(x: 0, y: 0, width: w, height: h).fill()
    // small mark, left-aligned block, vertically centered composition
    let mark = CGRect(x: 120, y: h/2 + 30, width: 150, height: 150)
    drawBars(in: mark)
    let name = "andrew dictate"
    let tagline = "hold a key, talk, get text."
    let sub = "free · open source · fully local"
    let nameAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 84, weight: .semibold), .foregroundColor: cream,
        .kern: -1.5]
    let tagAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 40, weight: .regular),
        .foregroundColor: cream.withAlphaComponent(0.62)]
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular),
        .foregroundColor: accent]
    NSString(string: name).draw(at: CGPoint(x: 120, y: h/2 - 90), withAttributes: nameAttrs)
    NSString(string: tagline).draw(at: CGPoint(x: 120, y: h/2 - 160), withAttributes: tagAttrs)
    NSString(string: sub).draw(at: CGPoint(x: 120, y: 96), withAttributes: subAttrs)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
    try! png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    renderIcon(size: size, to: out.appendingPathComponent("icon_\(size).png"))
}
renderOG(to: out.appendingPathComponent("og.png"))
print("rendered")
