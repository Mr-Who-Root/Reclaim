import AppKit

/// Draws the Reclaim app icon in any accent. Used for the Dock tint and by `scripts/make_icon.swift`.
enum IconRenderer {
    static func image(top: NSColor, bottom: NSColor, side: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(in: rect, top: top, bottom: bottom)
            return true
        }
    }

    static func draw(in rect: NSRect, top: NSColor, bottom: NSColor) {
        let s = rect.width / 1024
        // macOS icon grid: 824pt body centred in 1024 with a soft shadow.
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let radius = 185 * s
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        bottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: top.blended(withFraction: 0.12, of: .white) ?? top, ending: bottom)?.draw(in: body, angle: -90)
        // Gentle highlight in the upper half.
        let glow = NSBezierPath(ovalIn: NSRect(x: body.minX - 120 * s, y: body.midY + 60 * s, width: body.width + 240 * s, height: body.height))
        NSColor.white.withAlphaComponent(0.10).setFill()
        glow.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Drive glyph.
        drawSymbol("internaldrive.fill", pointSize: 330 * s, weight: .semibold,
                   center: NSPoint(x: body.midX, y: body.midY - 120 * s), color: .white)
        // Reclaim arrow above the drive.
        drawSymbol("arrow.counterclockwise", pointSize: 200 * s, weight: .bold,
                   center: NSPoint(x: body.midX, y: body.midY + 175 * s), color: NSColor.white.withAlphaComponent(0.92))
    }

    private static func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, center: NSPoint, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }

    /// Applies the accent-tinted icon to the Dock, or restores the bundle icon.
    @MainActor
    static func applyDockIcon(tinted: Bool, accent: Accent) {
        NSApp.applicationIconImage = tinted ? image(top: accent.nsColor, bottom: accent.deepNSColor, side: 512) : nil
    }
}
