import AppKit
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns  (also writes AppIcon.png next to it)

// Renders Lintel's icon: a lintel (the beam above a window) over a window pane, on a macOS-style squircle.
func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824 pt body centered in 1024, corner radius ~185.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Evening-sky background.
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.47, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.16, green: 0.22, blue: 0.33, alpha: 1)])!.draw(in: body, angle: -90)

    // Window pane under the lintel.
    let pane = NSRect(x: 250 * s, y: 196 * s, width: 524 * s, height: 420 * s)
    let paneShape = NSBezierPath(roundedRect: pane, xRadius: 46 * s, yRadius: 46 * s)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.08)])!.draw(in: paneShape, angle: -90)
    // Title strip of the pane, clipped to its rounded corners.
    NSGraphicsContext.saveGraphicsState()
    paneShape.addClip()
    NSColor.white.withAlphaComponent(0.14).setFill()
    NSBezierPath(rect: NSRect(x: pane.minX, y: pane.maxY - 70 * s, width: pane.width, height: 70 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.55).setStroke()
    paneShape.lineWidth = 10 * s
    paneShape.stroke()

    // The lintel: a glass beam with three tabs, the first one active.
    let beam = NSRect(x: 196 * s, y: 664 * s, width: 632 * s, height: 132 * s)
    let beamShape = NSBezierPath(roundedRect: beam, xRadius: 40 * s, yRadius: 40 * s)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.98), NSColor(srgbRed: 0.88, green: 0.92, blue: 0.97, alpha: 1)])!.draw(in: beamShape, angle: -90)
    let tabW: CGFloat = 168 * s, tabH: CGFloat = 60 * s, gap: CGFloat = 28 * s
    var x = beam.minX + 34 * s
    for i in 0..<3 {
        let tab = NSRect(x: x, y: beam.midY - tabH / 2, width: tabW, height: tabH)
        let color = i == 0 ? NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1) : NSColor(srgbRed: 0.16, green: 0.22, blue: 0.33, alpha: 0.22)
        color.setFill()
        NSBezierPath(roundedRect: tab, xRadius: tabH / 2, yRadius: tabH / 2).fill()
        x += tabW + gap
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge, as on Apple's icons.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1 * s, dy: 1 * s), xRadius: 184 * s, yRadius: 184 * s)
    edge.lineWidth = 2 * s
    edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: out.deletingPathExtension().appendingPathExtension("png"))
