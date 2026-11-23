import SwiftUI
import OiseauCore

/// The welcome carousel's pages: hello, the game's three moves, then the sign-up
/// (Android: ui/auth/WelcomeScreen.kt).
enum WelcomeSlide: Int, CaseIterable, Hashable {
    case hello, search, find, place, hunt

    /// The look's two fun colours, in turn.
    var color: Color {
        switch self {
        case .hello, .find, .hunt: return Zine.pink
        case .search, .place: return Zine.yellow
        }
    }

    /// Each sticker is stuck on a little askew, never twice the same way.
    var tilt: Double {
        switch self {
        case .hello: return -5
        case .search: return 4
        case .find: return -3
        case .place: return 5
        case .hunt: return -4
        }
    }
}

/// A pin or an icon floating around a slide's mascot, placed from the stage's centre.
private enum Prop {
    case pin(PinStyle, x: CGFloat, y: CGFloat, phase: Double)
    case icon(String, x: CGFloat, y: CGFloat, phase: Double)

    var phase: Double {
        switch self {
        case .pin(_, _, _, let p), .icon(_, _, _, let p): return p
        }
    }
}

private struct Intro {
    let pose: MascottePose
    let kicker: String
    let title: String
    let body: String
    let props: [Prop]
}

private func intro(_ slide: WelcomeSlide) -> Intro {
    switch slide {
    case .hello:
        return Intro(pose: .photo, kicker: "welcome_hello_kicker", title: "brand_name", body: "welcome_hello_body", props: [
            .icon("sparkles", x: -104, y: -78, phase: 0), .icon("sparkles", x: 100, y: 70, phase: 0.5),
        ])
    case .search:
        return Intro(pose: .search, kicker: "welcome_search_kicker", title: "welcome_search_title", body: "welcome_search_body", props: [
            .pin(PinStyle(.available), x: -100, y: -70, phase: 0),
            .pin(PinStyle(.available, wish: true), x: 98, y: -86, phase: 0.35),
            .pin(PinStyle(.available), x: 104, y: 62, phase: 0.7),
        ])
    case .find:
        return Intro(pose: .celebrate, kicker: "welcome_find_kicker", title: "welcome_find_title", body: "welcome_find_body", props: [
            .pin(PinStyle(.found), x: -102, y: -62, phase: 0.2),
            .icon("party_popper", x: 100, y: -84, phase: 0.6),
            .icon("camera", x: -96, y: 74, phase: 0.9),
        ])
    case .place, .hunt:
        return Intro(pose: .place, kicker: "welcome_place_kicker", title: "welcome_place_title", body: "welcome_place_body", props: [
            .pin(PinStyle(.mine), x: 100, y: -74, phase: 0.1),
            .icon("lightbulb", x: -102, y: -56, phase: 0.55),
        ])
    }
}

/// First screen for a visitor without an account (spec §4.1): a carousel that ends
/// on the sign-up form, with a way to the sign-in.
struct WelcomeView: View {
    var onLogin: () -> Void
    @State private var page: WelcomeSlide
    @State private var signUp = LoginModel(mode: .register)

    init(onLogin: @escaping () -> Void, page: WelcomeSlide = .hello) {
        self.onLogin = onLogin
        _page = State(initialValue: page)
    }

    var body: some View {
        let onLast = page == .hunt
        VStack(spacing: 0) {
            HStack {
                Dots(current: page)
                Spacer()
                if !onLast {
                    LinkButton(title: L("common_skip")) { withAnimation { page = .hunt } }
                        .accessibilityIdentifier("welcome.skip")
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 20)

            TabView(selection: $page) {
                ForEach(WelcomeSlide.allCases, id: \.self) { slide in
                    Group {
                        if slide == .hunt {
                            HuntPage(signUp: signUp, onLogin: onLogin)
                        } else {
                            IntroPage(slide: slide)
                        }
                    }
                    .tag(slide)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if !onLast {
                OpButton(title: L(page == .place ? "welcome_ready" : "common_next"), fullWidth: true) {
                    withAnimation { page = WelcomeSlide(rawValue: page.rawValue + 1) ?? .hunt }
                }
                .accessibilityIdentifier("welcome.next")
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .background(Zine.paper.ignoresSafeArea())
    }
}

/// One small square per step, outlined in black: seen ones black, the current one
/// long and in its slide's colour.
private struct Dots: View {
    let current: WelcomeSlide

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeSlide.allCases, id: \.self) { slide in
                let isCurrent = slide == current
                Rectangle()
                    .fill(isCurrent ? slide.color : (slide.rawValue < current.rawValue ? Zine.ink : Color.clear))
                    .frame(width: isCurrent ? 28 : 10, height: 10)
                    .overlay(Rectangle().stroke(Zine.ink, lineWidth: 1.5))
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel(L("welcome_page", current.rawValue + 1, WelcomeSlide.allCases.count))
    }
}

private struct IntroPage: View {
    let slide: WelcomeSlide

    var body: some View {
        let intro = intro(slide)
        ScrollView {
            VStack(spacing: 10) {
                Stage(intro: intro, color: slide.color, tilt: slide.tilt)
                Spacer().frame(height: 6)
                AuthKicker(text: L(intro.kicker))
                Text(L(intro.title))
                    .font(.zDisplay)
                    .foregroundStyle(Zine.ink)
                    .multilineTextAlignment(.center)
                Text(L(intro.body))
                    .font(.zBodyLarge)
                    .foregroundStyle(Zine.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The mascot on its sticker of the slide's colour, with its props bobbing around it.
private struct Stage: View {
    let intro: Intro
    let color: Color
    let tilt: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            // A slow 0..1 loop (3.2 s); frozen at 0 when animations are off.
            let clock = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
            let t = clock * 2 * .pi
            ZStack {
                StickerSquare(color: color, size: 176, tilt: tilt)
                Group {
                    if intro.pose == .photo {
                        // The original rotten bird, the one the game is named after.
                        Mascotte(.photo, label: L("brand_mascot"))
                            .frame(width: 180, height: 180)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Zine.ink, lineWidth: 4))
                            .rotationEffect(.degrees(sin(t) * 3))
                    } else {
                        Mascotte(intro.pose).frame(width: 190, height: 190)
                    }
                }
                .offset(y: sin(t) * 5)
                ForEach(Array(intro.props.enumerated()), id: \.offset) { _, prop in
                    let bob = sin((clock + prop.phase) * 2 * .pi) * 7
                    switch prop {
                    case .pin(let style, let x, let y, _):
                        Image(uiImage: PinRenderer.image(style)).offset(x: x, y: y + bob)
                    case .icon(let name, let x, let y, _):
                        LucideIcon(name, size: 22)
                            .foregroundStyle(Zine.ink)
                            .frame(width: 40, height: 40)
                            .background(color, in: Circle())
                            .overlay(Circle().stroke(Zine.ink, lineWidth: 1.5))
                            .offset(x: x, y: y + bob)
                    }
                }
            }
            .frame(width: 260, height: 260)
        }
        .accessibilityHidden(intro.pose != .photo)
    }
}

/// The last page: « Prêt pour la chasse ? » and the sign-up form.
private struct HuntPage: View {
    let signUp: LoginModel
    let onLogin: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                AuthHeader(pose: .wave, kicker: L("welcome_hunt_kicker"), title: L("welcome_hunt_title"), color: WelcomeSlide.hunt.color)
                Spacer().frame(height: 4)
                LoginForm(model: signUp, submitLabel: L("welcome_hunt_submit"))
                LinkButton(title: L("login_to_login"), action: onLogin)
                    .accessibilityIdentifier("welcome.toLogin")
                LegalLinks()
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
