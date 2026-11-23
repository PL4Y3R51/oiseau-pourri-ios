import UIKit
import OiseauCore

/// Draws map pins as images for the map's symbol layer, one per [PinStyle]
/// (Android: ui/map/PinSprites.kt, same geometry in points). The look follows the
/// mascot, not a generic map pin: a drop in the state colour outlined in ink, a
/// cream disc with the Lucide bird inside.
enum PinRenderer {
    static let width: CGFloat = 44
    static let height: CGFloat = 54
    private static let cx = width / 2
    private static let cy: CGFloat = 20 // drop circle centre
    private static let radius: CGFloat = 14
    private static let tipY = height - 3

    private static var cache: [String: UIImage] = [:]

    static func image(_ style: PinStyle) -> UIImage {
        if let hit = cache[style.spriteId] { return hit }
        let image = render(style)
        cache[style.spriteId] = image
        return image
    }

    private static func render(_ style: PinStyle) -> UIImage {
        let ink = UIColor(hex: 0x111111)
        let cream = UIColor(hex: 0xF7F6F1)
        let fill = Zine.pin(style.kind)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let g = ctx.cgContext
            // Not-yet-found pins are slightly see-through, like the web (opacity .85).
            if style.kind == .available {
                g.setAlpha(0.85)
                g.beginTransparencyLayer(auxiliaryInfo: nil)
            }

            if style.wish {
                Zine.pinWish.withAlphaComponent(0.45).setFill()
                UIBezierPath(arcCenter: CGPoint(x: cx, y: cy), radius: radius + 5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
            }

            // The drop: the circle and its two tangents to the tip.
            let d = tipY - cy
            let phi = asin(radius / d)
            let drop = UIBezierPath()
            drop.move(to: CGPoint(x: cx, y: tipY))
            drop.addLine(to: CGPoint(x: cx - radius * cos(phi), y: cy + radius * sin(phi)))
            drop.addArc(withCenter: CGPoint(x: cx, y: cy), radius: radius, startAngle: .pi - phi, endAngle: phi, clockwise: true)
            drop.close()
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 2.5, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            fill.setFill()
            drop.fill()
            g.restoreGState()
            ink.setStroke()
            drop.lineWidth = 2
            drop.lineJoinStyle = .round
            drop.stroke()

            // Cream disc and the bird glyph in the state colour (darker for the grey state).
            cream.setFill()
            UIBezierPath(arcCenter: CGPoint(x: cx, y: cy), radius: 9.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).fill()
            let glyph = style.kind == .available ? UIColor(hex: 0x5D6B85) : fill
            drawIcon("bird", center: CGPoint(x: cx, y: cy), size: 13, color: glyph)

            if style.wish { badge(CGPoint(x: cx + 12, y: cy - 12), fill: Zine.pinWish, icon: "star", ink: ink) }
            if style.reported { dot(CGPoint(x: cx - 12, y: cy - 12), fill: UIColor(hex: 0xFF5FA2), ink: ink) }
            if style.isPrivate { badge(CGPoint(x: cx + 13, y: cy + 9), fill: UIColor(hex: 0x8C7636), icon: "house", ink: ink) }

            if style.kind == .available { g.endTransparencyLayer() }
        }
    }

    private static func drawIcon(_ name: String, center: CGPoint, size: CGFloat, color: UIColor) {
        guard let icon = UIImage(named: "lucide_\(name)")?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        icon.draw(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
    }

    private static func badge(_ c: CGPoint, fill: UIColor, icon: String, ink: UIColor) {
        let circle = UIBezierPath(arcCenter: c, radius: 6.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        fill.setFill()
        circle.fill()
        ink.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        drawIcon(icon, center: c, size: 8, color: ink)
    }

    private static func dot(_ c: CGPoint, fill: UIColor, ink: UIColor) {
        let circle = UIBezierPath(arcCenter: c, radius: 4.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        fill.setFill()
        circle.fill()
        ink.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
    }
}
