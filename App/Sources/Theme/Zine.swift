import SwiftUI
import UIKit
import OiseauCore

/// The palette: the project's one look, Zine (spec §14). A mirror of the web's
/// `packages/ui/src/tokens.css` and Android's ui/theme/Color.kt: change a value
/// there, change it here.
enum Zine {
    static let paper = Color(hex: 0xF7F6F1) // --bg
    static let panel = Color.white // --panel
    static let ink = Color(hex: 0x111111) // --text, --accent, outlines and hard shadows
    static let muted = Color(hex: 0x555555) // --muted
    static let yellow = Color(hex: 0xD7F23A) // --on-accent: type on black, the happy moments
    static let pink = Color(hex: 0xFF5FA2) // --mark: what is ON, the section-title pastille
    static let found = Color(hex: 0x1F7A43) // --found
    static let surfaceVariant = Color(hex: 0xECEBE4)
    static let error = Color(hex: 0xB3123A)
    static let privateInk = Color(hex: 0x8C7636)
    static let archivedInk = Color(hex: 0x8A5600)
    static let wishInk = Color(hex: 0x7A5A00)

    /// Map pins, one colour per state (tokens.css --pin-*).
    static func pin(_ kind: PinKind) -> UIColor {
        switch kind {
        case .available: return UIColor(hex: 0x777777)
        case .found: return UIColor(hex: 0x1F7A43)
        case .mine: return UIColor(hex: 0x2457C5)
        case .archived: return UIColor(hex: 0xC27C0E)
        }
    }

    static let pinWish = UIColor(hex: 0xF4B740)

    /// Corner radii (index.css): buttons and inputs, cards, sheets.
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 16

    /// The outline of controls (--line-w), the raised offset (--press-offset), the floating one.
    static let lineWidth: CGFloat = 1.5
    static let pressOffset: CGFloat = 2
    static let floatOffset: CGFloat = 3
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Type

/// Syne (SIL OFL), the one font of the look. A variable font: each weight is set on
/// its `wght` axis, as Android has to (the default instance would be Regular).
extension Font {
    static func syne(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(UIFont.syne(size, weight))
    }

    /// The roles of Android's ui/theme/Type.kt (Material's, on Syne).
    static let zDisplay = syne(34, 800) // « Attrapé ! », the welcome titles
    static let zAuthTitle = syne(27, 800)
    static let zHeadline = syne(23, 800) // page titles
    static let zTitleLarge = syne(20, 800) // sheet titles
    static let zTitle = syne(16, 700)
    static let zBodyLarge = syne(16)
    static let zBody = syne(14)
    static let zBodySmall = syne(12.5)
    static let zLabel = syne(16, 700) // buttons
    static let zLabelSmall = syne(11, 600)
}

extension UIFont {
    private static let wghtAxis = 0x7767_6874 // 'wght'

    static func syne(_ size: CGFloat, _ weight: CGFloat = 400) -> UIFont {
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(name: "Syne-Regular", size: size).addingAttributes([variation: [wghtAxis: weight]])
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - Relief

/// The Zine relief (spec §14.3): what is chosen or touched stands off the page on a
/// hard black shadow, outlined in black, like a sticker, and is pressed in (shadow
/// gone, shifted into it) once `sunk`.
struct Relief<S: Shape>: ViewModifier {
    var shape: S
    var sunk = false
    var offset: CGFloat = Zine.pressOffset
    var outline = true

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .overlay { if outline { shape.stroke(Zine.ink, lineWidth: Zine.lineWidth) } }
            .background { shape.fill(Zine.ink).offset(x: offset, y: offset).opacity(sunk ? 0 : 1) }
            .offset(x: sunk ? offset : 0, y: sunk ? offset : 0)
    }
}

extension View {
    func relief<S: Shape>(_ shape: S, sunk: Bool = false, offset: CGFloat = Zine.pressOffset, outline: Bool = true) -> some View {
        modifier(Relief(shape: shape, sunk: sunk, offset: offset, outline: outline))
    }

    /// A floating panel's shadow, never pressed.
    func floating<S: Shape>(_ shape: S) -> some View {
        relief(shape, offset: Zine.floatOffset)
    }
}

// MARK: - Strings

/// A string of Localizable.xcstrings (the Android string names), formatted.
func L(_ key: String, _ args: CVarArg...) -> String { L(key, args: args) }

func L(_ key: String, args: [CVarArg]) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

extension UiText {
    var text: String {
        switch self {
        case .key(let key, let args): return L(key, args: args)
        case .raw(let s): return s
        }
    }
}

/// What a failed call says to the player.
func uiText(_ error: Error) -> UiText {
    (error as? ApiError)?.toUiText() ?? .of("error_network")
}
