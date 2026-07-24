import AppKit

// og image compositor: dark bg + the badge (from icon_1024.png) + type.
let art = FileManager.default.currentDirectoryPath
guard let badge = NSImage(contentsOfFile: art + "/icon_1024.png") else { fatalError("no icon_1024") }

let W: CGFloat = 1200, H: CGFloat = 630
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor(srgbRed: 0x0C/255, green: 0x0C/255, blue: 0x0E/255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

NSGraphicsContext.current?.imageInterpolation = .high
badge.draw(in: NSRect(x: 80, y: 95, width: 440, height: 440))

let goldPale = NSColor(srgbRed: 0xF9/255, green: 0xE9/255, blue: 0xA8/255, alpha: 1)
let gold = NSColor(srgbRed: 0xE5/255, green: 0xBE/255, blue: 0x62/255, alpha: 1)

let name = NSAttributedString(string: "andrew dictate", attributes: [
    .font: NSFont.systemFont(ofSize: 84, weight: .semibold),
    .foregroundColor: goldPale, .kern: -1.5])
name.draw(at: NSPoint(x: 580, y: 330))

let tag = NSAttributedString(string: "escape the keyboard.", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 36, weight: .regular),
    .foregroundColor: gold])
tag.draw(at: NSPoint(x: 584, y: 268))

let sub = NSAttributedString(string: "free · open source · fully local", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 25, weight: .regular),
    .foregroundColor: goldPale.withAlphaComponent(0.5)])
sub.draw(at: NSPoint(x: 584, y: 96))
img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
try! png.write(to: URL(fileURLWithPath: art + "/og.png"))
print("og composed")
