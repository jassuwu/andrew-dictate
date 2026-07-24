import AppKit
import CoreGraphics

// andrew dictate — icon pipeline from the raster badge (art/icon-source.png).
// finds the badge's bounding box (dark pixels on light margin), crops square,
// re-clips to the macOS icon rounded-rect, emits all sizes.

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
        // badge pixels are dark or saturated gold; margin is near-white
        let bright = (c.redComponent + c.greenComponent + c.blueComponent) / 3
        if bright < 0.82 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
let bw = maxX - minX + 1, bh = maxY - minY + 1
let side = max(bw, bh)
// center the square crop on the badge
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
let half = side / 2
let cropX = max(0, min(w - side, cx - half))
let cropY = max(0, min(h - side, cy - half))
print("badge bbox: \(minX),\(minY) → \(maxX),\(maxY)  crop: \(cropX),\(cropY) side \(side)")

guard let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let cropped = cg.cropping(to: CGRect(x: cropX, y: cropY, width: side, height: side))
else { fatalError("crop failed") }

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    // macOS icon grid: content inset ~9.8%, corner radius ~22.6% of content
    let inset = s * 0.02  // the badge already carries its own margin/rim — keep tight
    let contentRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let clip = NSBezierPath(roundedRect: contentRect, xRadius: contentRect.width * 0.225, yRadius: contentRect.width * 0.225)
    clip.setClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    let drawRep = NSBitmapImageRep(cgImage: cropped)
    drawRep.draw(in: contentRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    image.unlockFocus()
    guard let outTiff = image.tiffRepresentation, let outRep = NSBitmapImageRep(data: outTiff),
          let png = outRep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size).png"))
}
print("icons rendered")
