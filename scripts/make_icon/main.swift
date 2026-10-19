// Renders Reclaim's AppIcon PNGs into the asset catalog.
// Usage: scripts/make_icon.sh   (compiles this with the app's IconRenderer)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let accent = Accent.ocean
let sizes: [(name: String, px: Int)] = [
    ("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128),
    ("128@2x", 256), ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024),
]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    IconRenderer.draw(in: NSRect(x: 0, y: 0, width: px, height: px), top: accent.nsColor, bottom: accent.deepNSColor)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("Wrote \(sizes.count) icons to \(out.path)")
