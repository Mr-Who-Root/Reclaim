// Renders the DMG window background: the Reclaim gradient, a title, and an arrow from the app to Applications.
// Usage: scripts/make_dmg.sh   (compiles this with the app's Accent colours)
//        make_dmg_background <out.png> <scale>
import AppKit

/// Window content size in points, and where Finder places the two icons (centres). make_dmg.sh uses the same numbers.
let size = NSSize(width: 640, height: 400)
let appCenter = NSPoint(x: 170, y: 200)
let applicationsCenter = NSPoint(x: 470, y: 200)

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let accent = Accent.ocean
let top = accent.nsColor.blended(withFraction: 0.10, of: .white)!
let bottom = accent.nsColor.blended(withFraction: 0.70, of: accent.deepNSColor)!

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

/// Finder measures from the top-left; AppKit draws from the bottom-left.
func flip(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x, y: size.height - p.y) }
let bounds = NSRect(origin: .zero, size: size)

// Background: the accent gradient with two soft glows, like the app's vivid theme.
NSGradient(starting: top, ending: bottom)!.draw(in: bounds, angle: -90)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), .clear])!
    .draw(fromCenter: flip(NSPoint(x: 600, y: 0)), radius: 0, toCenter: flip(NSPoint(x: 600, y: 0)), radius: 420, options: [])
NSGradient(colors: [accent.deepNSColor.withAlphaComponent(0.45), .clear])!
    .draw(fromCenter: flip(NSPoint(x: 0, y: 400)), radius: 0, toCenter: flip(NSPoint(x: 0, y: 400)), radius: 380, options: [])

func drawText(_ text: String, font: NSFont, color: NSColor, centerY: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    let height = (text as NSString).size(withAttributes: attrs).height
    (text as NSString).draw(in: NSRect(x: 0, y: size.height - centerY - height / 2, width: size.width, height: height), withAttributes: attrs)
}

let rounded = NSFont.systemFont(ofSize: 22, weight: .bold).fontDescriptor.withDesign(.rounded)!
drawText("Drag Reclaim to Applications", font: NSFont(descriptor: rounded, size: 22)!, color: .white, centerY: 52)
drawText("Then open it from your Applications folder.", font: .systemFont(ofSize: 13, weight: .medium),
         color: NSColor.white.withAlphaComponent(0.8), centerY: 80)
drawText("Nothing leaves your Mac, and removals always go to the Trash.", font: .systemFont(ofSize: 11),
         color: NSColor.white.withAlphaComponent(0.6), centerY: 366)

// Arrow between the icons, bowed slightly upward.
let start = flip(NSPoint(x: appCenter.x + 84, y: appCenter.y))
let end = flip(NSPoint(x: applicationsCenter.x - 84, y: applicationsCenter.y))
let control = flip(NSPoint(x: (appCenter.x + applicationsCenter.x) / 2, y: appCenter.y - 26))
let arrow = NSBezierPath()
arrow.move(to: start)
arrow.curve(to: end, controlPoint1: control, controlPoint2: control)
arrow.lineWidth = 5
arrow.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.92).setStroke()
arrow.stroke()

let angle = atan2(end.y - control.y, end.x - control.x)
let head = NSBezierPath()
for side in [-1.0, 1.0] {
    let a = angle + .pi - side * .pi / 5
    head.move(to: end)
    head.line(to: NSPoint(x: end.x + 16 * cos(a), y: end.y + 16 * sin(a)))
}
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
