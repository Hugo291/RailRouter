import AppKit

// Native vector artwork, rendered at every macOS icon size (no external assets).
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(red: 0.06, green: 0.26, blue: 0.32, alpha: 1), ending: NSColor(red: 0.20, green: 0.12, blue: 0.40, alpha: 1))!.draw(in: background, angle: -45)
    for (y, opacity) in [(CGFloat(305), CGFloat(0.30)), (CGFloat(415), CGFloat(0.55)), (CGFloat(525), CGFloat(1.0))] {
        let card = NSBezierPath(roundedRect: NSRect(x: 230, y: y, width: 564, height: 176), xRadius: 48, yRadius: 48)
        NSColor.white.withAlphaComponent(opacity).setFill()
        card.fill()
        if opacity == 1 {
            NSColor(red: 0.06, green: 0.55, blue: 0.48, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 275, y: y + 64, width: 48, height: 48)).fill()
            let stroke = NSBezierPath(roundedRect: NSRect(x: 365, y: y + 70, width: 346, height: 36), xRadius: 18, yRadius: 18)
            NSColor(red: 0.13, green: 0.22, blue: 0.32, alpha: 1).setFill()
            stroke.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(size).png"))
}
