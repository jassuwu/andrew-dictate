import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// andrew dictate — icon pipeline from the raster badge (art/icon-source.png).
// crops the badge, masks icon corners, emits EXACT-pixel PNGs via CGBitmapContext
// (NSImage.lockFocus renders at screen scale and silently doubles dimensions,
// which corrupts the asset catalog and degrades NSApp.applicationIconImage).

let args = CommandLine.arguments
let srcPath = args.count > 1 ? args[1] : "icon-source.png"
let outDir = args.count > 2 ? args[2] : "."

guard let img = NSImage(contentsOfFile: srcPath),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else { fatalError("cannot load \(srcPath)") }

let w = rep.pixelsWide, h = rep.pixelsHigh
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        let bright = (c.redComponent + c.greenComponent + c.blueComponent) / 3
        if bright < 0.82 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
let bw = maxX - minX + 1, bh = maxY - minY + 1
let side = max(bw, bh)
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
let half = side / 2
let cropX = max(0, min(w - side, cx - half))
let cropY = max(0, min(h - side, cy - half))

guard let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let cropped = cg.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side))
else { fatalError("crop failed") }

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("dest fail \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize fail \(path)") }
}

func renderIcon(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("ctx fail") }
    ctx.interpolationQuality = .high
    let inset = s * 0.02
    let content = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = content.width * 0.225
    let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(cropped, in: content)
    guard let out = ctx.makeImage() else { fatalError("makeImage fail") }
    return out
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(renderIcon(pixels: size), to: "\(outDir)/icon_\(size).png")
}
// menu bar sizes (full-color badge, 1x/2x)
for size in [18, 36] {
    writePNG(renderIcon(pixels: size), to: "\(outDir)/menubar_\(size).png")
}
print("icons rendered (exact pixels)")
