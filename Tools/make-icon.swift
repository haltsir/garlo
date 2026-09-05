import AppKit

// Draws the app icon: the throat glyph in white on a teal rounded square.
// Keep visually in sync with MenuBarIcon.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Garlo.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(_ size: Int, scale: Int, name: String) {
    let px = size * scale
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let s = CGFloat(px) / 128
    let inset = 10 * s
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: 26 * s, yRadius: 26 * s)
    let top = NSColor(srgbRed: 0.16, green: 0.49, blue: 0.53, alpha: 1)
    let bottom = NSColor(srgbRed: 0.09, green: 0.33, blue: 0.37, alpha: 1)
    NSGradient(starting: top, ending: bottom)?.draw(in: bg, angle: -90)

    let path = NSBezierPath()
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
    path.move(to: p(40, 98))
    path.line(to: p(88, 98))
    path.line(to: p(88, 80))
    path.curve(to: p(74, 52), controlPoint1: p(88, 66), controlPoint2: p(74, 64))
    path.line(to: p(74, 30))
    path.line(to: p(54, 30))
    path.line(to: p(54, 52))
    path.curve(to: p(40, 80), controlPoint1: p(54, 64), controlPoint2: p(40, 66))
    path.close()
    path.lineWidth = 8 * s
    path.lineJoinStyle = .round
    NSColor.white.setStroke()
    path.stroke()
    let foot = NSBezierPath()
    foot.move(to: p(50, 22))
    foot.line(to: p(78, 22))
    foot.lineWidth = 8 * s
    foot.lineCapStyle = .round
    foot.stroke()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

for size in [16, 32, 128, 256, 512] {
    draw(size, scale: 1, name: "icon_\(size)x\(size)")
    draw(size, scale: 2, name: "icon_\(size)x\(size)@2x")
}
print("wrote iconset to \(outDir)")
