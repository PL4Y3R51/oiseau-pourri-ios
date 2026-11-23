import SwiftUI
import OiseauCore

// The look the signed-out screens share (Android: ui/auth/AuthStyle.kt): the mascot
// on a coloured sticker stuck on askew, a kicker on a black label, a big title.

/// The square of colour a mascot stands on, outlined in black on the floating shadow.
struct StickerSquare: View {
    let color: Color
    let size: CGFloat
    let tilt: Double

    var body: some View {
        color
            .frame(width: size, height: size)
            .relief(Rectangle(), offset: Zine.floatOffset)
            .rotationEffect(.degrees(tilt))
    }
}

/// The small capitals above a title, on a black label with yellow type.
struct AuthKicker: View {
    let text: String

    var body: some View {
        Text(text.uppercased(with: Locale(identifier: "fr_CH")))
            .font(.syne(16, 800))
            .tracking(2)
            .foregroundStyle(Zine.yellow)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Zine.ink)
    }
}

/// The head of a form page: the mascot on its sticker, the kicker and the title.
struct AuthHeader: View {
    let pose: MascottePose
    let kicker: String
    let title: String
    var color: Color = Zine.pink

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                StickerSquare(color: color, size: 92, tilt: -4)
                Mascotte(pose).frame(width: 104, height: 104)
            }
            .padding(.top, 6)
            AuthKicker(text: kicker)
            Text(title)
                .font(.zAuthTitle)
                .foregroundStyle(Zine.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Public pages the app links out to (the web renders the legal texts).
enum LegalDoc: String, CaseIterable {
    case cgu = "/cgu"
    case privacy = "/confidentialite"
    case charter = "/charte"

    var label: String {
        switch self {
        case .cgu: return L("legal_cgu")
        case .privacy: return L("legal_privacy")
        case .charter: return L("legal_charter")
        }
    }

    var url: URL { AppConfig.webBaseURL.appendingPathComponent(String(rawValue.dropFirst())) }
}

/// One centred line of legal links, « · » between them.
struct LegalLinks: View {
    @Environment(\.openURL) private var openURL

    init() {}

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(LegalDoc.allCases.enumerated()), id: \.offset) { i, doc in
                if i > 0 { Text("·").font(.zBodySmall).foregroundStyle(Zine.muted) }
                LinkButton(title: doc.label, color: Zine.muted, font: .zBodySmall) { openURL(doc.url) }
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
