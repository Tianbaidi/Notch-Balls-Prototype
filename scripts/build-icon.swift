import AppKit

// Package the approved artwork within a deterministic macOS icon silhouette.
// Coordinates describe the tile in the original 1254-pixel presentation preview.
guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: build-icon source.png output.png")
}
let side = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let scale = CGFloat(side) / 1254
let tile = CGRect(x: 112 * scale, y: 120 * scale,
                  width: 1028 * scale, height: 1024 * scale)
NSBezierPath(roundedRect: tile, xRadius: 230 * scale, yRadius: 230 * scale).addClip()
artwork.draw(in: CGRect(x: 0, y: 0, width: side, height: side), from: .zero,
             operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
