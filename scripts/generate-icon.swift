import AppKit

// Découpe l'illustration carrée (scripts/icon-artwork.png) à la forme d'icône macOS, à chaque taille.
// usage : swift scripts/generate-icon.swift scripts/icon-artwork.png RailRouter/Assets.xcassets/AppIcon.appiconset
let artwork = NSImage(contentsOfFile: CommandLine.arguments[1])!
let output = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Grille d'icône Apple : carré arrondi de 824 px sur un canevas de 1024.
    let scale = CGFloat(size) / 1024
    let frame = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: frame, xRadius: 185 * scale, yRadius: 185 * scale)
    shape.addClip()
    artwork.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    // Liseré intérieur : le bas de l'illustration est presque blanc, il se perdrait sur un fond clair.
    NSColor(red: 0.10, green: 0.25, blue: 0.45, alpha: 0.22).setStroke()
    shape.lineWidth = 12 * scale
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(size).png"))
}
