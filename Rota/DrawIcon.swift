import AppKit

// Reproducible vector-drawn app icon. Coordinates use a 1024-point canvas.
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.23, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 3
    tile.stroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 215, y: 215, width: 594, height: 594))
    NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
    ring.lineWidth = 22
    ring.stroke()
    for i in 0..<12 {
        let angle = CGFloat(i) * .pi / 6
        let outer: CGFloat = 264
        let inner: CGFloat = i % 3 == 0 ? 222 : 245
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: 512 + sin(angle) * inner, y: 512 + cos(angle) * inner))
        tick.line(to: NSPoint(x: 512 + sin(angle) * outer, y: 512 + cos(angle) * outer))
        tick.lineWidth = i % 3 == 0 ? 12 : 6
        tick.lineCapStyle = .round
        NSColor.white.withAlphaComponent(i % 3 == 0 ? 0.9 : 0.35).setStroke()
        tick.stroke()
    }
    func triangle(_ points: [NSPoint], color: NSColor) {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        color.setFill()
        path.fill()
    }
    triangle([NSPoint(x: 670,y: 734), NSPoint(x: 435,y: 567), NSPoint(x: 589,y: 457)], color: NSColor(calibratedRed: 0.25, green: 0.89, blue: 0.76, alpha: 1))
    triangle([NSPoint(x: 354,y: 290), NSPoint(x: 435,y: 567), NSPoint(x: 589,y: 457)], color: NSColor(calibratedWhite: 0.94, alpha: 1))
    NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 489,y: 489,width: 46,height: 46)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
}
