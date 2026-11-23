import Foundation

/// A screen of the signed-in app that a web page stands for.
public enum AppScreen: Sendable { case map, collection, place, leaderboard, profile, settings, preferences, order, orderHistory }

/// The signed-out page of `/` and `/login` (web: LandingPage, LoginPage `?mode=register`).
public enum WelcomePage: Sendable { case landing, login, register }

/// Which e-mail link brought the player to the account page (web: `?email=verified|approved`).
public enum EmailLanding: Sendable { case verified, approved }

/// A page of oiseaupourri.ch the app opens itself (Universal Links; Android:
/// domain/DeepLink.kt, App Links, spec §16). The paths are the web's routes and the
/// links our e-mails carry. The legal texts and the admin page are not among them:
/// the app opens those in the browser.
public enum DeepLink: Equatable, Sendable {
    case screen(AppScreen)
    /// `/u/:id`, a player's public profile.
    case profile(String)
    /// `/` and `/login`.
    case welcome(WelcomePage)
    /// `/settings/compte`, maybe as the web lands there after an e-mail link.
    case account(landed: EmailLanding? = nil, failed: Bool = false)
    /// `/reset-password?token=…`: choose a new password (signed out).
    case resetPassword(String?)
    /// `/auth/verify-email?token=…`: an address confirmation or the approval of an
    /// e-mail change. The app calls the endpoint itself, without the link's
    /// callbackURL — with it the answer is a redirect to the web page.
    case verifyEmail(token: String, landing: EmailLanding)

    private static let screens: [String: AppScreen] = [
        "/place": .place,
        "/collection": .collection,
        "/leaderboard": .leaderboard,
        "/profile": .profile,
        "/settings": .settings,
        "/settings/preferences": .preferences,
        "/commander-oiseaux": .order,
        "/commander-oiseaux/historique": .orderHistory,
    ]

    /// The paths a Universal Links claim must list: exactly the pages parsed here
    /// (plus the `/u/` prefix).
    public static let claimedPaths: [String] = ["/", "/login", "/settings/compte", "/reset-password", "/auth/verify-email"] + screens.keys.sorted()

    /// The link's page, or nil for one the app doesn't open (it then stays where it is).
    public static func parse(_ url: String) -> DeepLink? {
        guard let comps = URLComponents(string: url) else { return nil }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        let q = query(comps.percentEncodedQuery)
        if let screen = screens[path] { return .screen(screen) }
        switch path {
        case "/": return .welcome(.landing)
        case "/login": return .welcome(q["mode"] == "register" ? .register : .login)
        case "/settings/compte": return .account(landed: landing(q["email"]), failed: q["error"] != nil)
        case "/reset-password": return .resetPassword(nonBlank(q["token"]))
        case "/auth/verify-email":
            guard let token = nonBlank(q["token"]) else { return nil }
            // The landing is the one the web page would show: it rides in the callbackURL.
            let back = q["callbackURL"].flatMap { URLComponents(string: $0) }
            return .verifyEmail(token: token, landing: landing(query(back?.percentEncodedQuery)["email"]) ?? .verified)
        default:
            guard path.hasPrefix("/u/") else { return nil }
            let id = String(path.dropFirst(3))
            guard !id.trimmingCharacters(in: .whitespaces).isEmpty, !id.contains("/") else { return nil }
            return .profile(id)
        }
    }

    private static func landing(_ v: String?) -> EmailLanding? {
        switch v {
        case "verified": return .verified
        case "approved": return .approved
        default: return nil
        }
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    /// Form decoding (`+` is a space); a broken escape is kept as typed.
    private static func decode(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private static func query(_ raw: String?) -> [String: String] {
        var out: [String: String] = [:]
        for part in (raw ?? "").split(separator: "&") where !part.isEmpty {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            out[decode(String(kv[0]))] = decode(kv.count > 1 ? String(kv[1]) : "")
        }
        return out
    }
}
