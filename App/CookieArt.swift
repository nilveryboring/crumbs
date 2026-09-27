import AppKit

/// The Crumbs cookie, drawn in code so the app icon, menu bar glyph and
/// empty state stay one drawing. `scripts/make-icon.sh` renders the icon set
/// from this file.
enum CookieArt {
    // Unit-space geometry (0…1, y up) shared by every size.
    private static let center = CGPoint(x: 0.46, y: 0.53)
    private static let radius: CGFloat = 0.29
    private static let bites: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 0.725, y: 0.675), 0.085),
        (CGPoint(x: 0.665, y: 0.76), 0.095),
        (CGPoint(x: 0.575, y: 0.815), 0.08),
    ]
    private static let chips: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 0.35, y: 0.62), 0.042),
        (CGPoint(x: 0.50, y: 0.45), 0.046),
        (CGPoint(x: 0.33, y: 0.42), 0.034),
        (CGPoint(x: 0.53, y: 0.66), 0.03),
        (CGPoint(x: 0.62, y: 0.50), 0.036),
        (CGPoint(x: 0.43, y: 0.31), 0.028),
    ]
    private static let crumbs: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 0.80, y: 0.40), 0.034),
        (CGPoint(x: 0.85, y: 0.27), 0.024),
        (CGPoint(x: 0.74, y: 0.22), 0.02),
    ]

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawIcon(in: ctx, size: rect.width)
            return true
        }
    }

    /// Template glyph for the menu bar: the system tints it.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillEllipse(in: circle(center, radius * 1.18, s))
            ctx.setBlendMode(.destinationOut)
            for (p, r) in bites { ctx.fillEllipse(in: circle(p, r * 1.25, s)) }
            for (p, r) in chips.prefix(4) { ctx.fillEllipse(in: circle(p, r * 1.15, s)) }
            ctx.setBlendMode(.normal)
            for (p, r) in crumbs.prefix(2) { ctx.fillEllipse(in: circle(p, r * 1.5, s)) }
            ctx.endTransparencyLayer()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func drawIcon(in ctx: CGContext, size s: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // macOS icon grid: 824/1024 body, continuous-corner squircle.
        let inset = s * 100 / 1024
        let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let squircle = CGPath(roundedRect: body, cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(squircle)
        ctx.setFillColor(rgb(0xFFF3DD))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let paper = CGGradient(colorsSpace: space, colors: [rgb(0xFFF7E8), rgb(0xF4D7A6)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

        // Cookie, then bite it. The layer's shadow follows the bitten shape.
        ctx.setShadow(offset: CGSize(width: s * 0.012, height: -s * 0.03), blur: s * 0.035,
                      color: CGColor(red: 0.45, green: 0.25, blue: 0.08, alpha: 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.saveGState()
        ctx.addEllipse(in: circle(center, radius, s))
        ctx.clip()
        let dough = CGGradient(colorsSpace: space, colors: [rgb(0xE9AE5E), rgb(0xC77F37)] as CFArray, locations: [0, 1])!
        let c = CGPoint(x: center.x * s, y: center.y * s)
        ctx.drawRadialGradient(dough, startCenter: CGPoint(x: c.x - s * 0.08, y: c.y + s * 0.1), startRadius: 0,
                               endCenter: c, endRadius: radius * s, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(red: 0.55, green: 0.3, blue: 0.1, alpha: 0.35))
        ctx.setLineWidth(s * 0.008)
        ctx.strokeEllipse(in: circle(center, radius - 0.004, s))
        for (p, r) in chips {
            ctx.setFillColor(rgb(0x4B2A16))
            ctx.fillEllipse(in: circle(p, r, s))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
            ctx.fillEllipse(in: circle(CGPoint(x: p.x - r * 0.3, y: p.y + r * 0.3), r * 0.35, s))
        }
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)) // destinationOut removes by source alpha
        for (p, r) in bites { ctx.fillEllipse(in: circle(p, r, s)) }
        ctx.endTransparencyLayer()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        for (p, r) in crumbs {
            ctx.setFillColor(rgb(0xCF8A42))
            ctx.fillEllipse(in: circle(p, r, s))
            ctx.setFillColor(CGColor(red: 0.45, green: 0.25, blue: 0.08, alpha: 0.25))
            ctx.fillEllipse(in: circle(CGPoint(x: p.x + r * 0.2, y: p.y - r * 0.25), r * 0.55, s))
        }
        ctx.restoreGState()
    }

    private static func circle(_ p: CGPoint, _ r: CGFloat, _ s: CGFloat) -> CGRect {
        CGRect(x: (p.x - r) * s, y: (p.y - r) * s, width: 2 * r * s, height: 2 * r * s)
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
