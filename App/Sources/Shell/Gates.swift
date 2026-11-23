import SwiftUI
import OiseauCore

// The blocking screens of a signed-in launch (Android: ui/gates/Gates.kt), and the
// links of oiseaupourri.ch the app opens itself (Universal Links, Android App Links).

extension View {
    /// The terms gate over the signed-in app, while the account hasn't accepted the
    /// current version. The « Quoi de neuf » notes are Android's: iOS has none yet.
    func firstRunGates() -> some View { modifier(FirstRunGates()) }
}

private struct FirstRunGates: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let gate = app.prefs.flatMap { firstRunGate($0, lastSeenRelease: nil, latestRelease: "") }
        content
            .fullScreenCover(isPresented: .constant(gate == .terms)) {
                TermsGate { Task { await app.acceptCurrentTerms() } }
                    .interactiveDismissDisabled()
            }
            .task(id: app.prefs?.onboarded) {
                // The welcome carousel stood in for the onboarding: record it once.
                if let p = app.prefs, shouldMarkOnboarded(p) { await app.markOnboarded() }
            }
    }
}

/// Blocking acceptance of the CGU + privacy policy (spec §13): « J'accepte » only.
struct TermsGate: View {
    let onAccept: () -> Void

    var body: some View {
        let terms = L("legal_terms_link")
        let privacy = L("legal_privacy_link")
        var text = AttributedString(L("terms_body", terms, privacy))
        for (part, doc) in [(terms, LegalDoc.cgu), (privacy, LegalDoc.privacy)] {
            if let range = text.range(of: part) {
                text[range].link = doc.url
                text[range].underlineStyle = .single
            }
        }
        return ScrollView {
            VStack(spacing: 16) {
                Mascotte(.cartoon).frame(width: 160, height: 160)
                Text(L("terms_title")).font(.zTitleLarge).foregroundStyle(Zine.ink).multilineTextAlignment(.center)
                Text(text).font(.zBody).foregroundStyle(Zine.muted).multilineTextAlignment(.center).tint(Zine.ink)
                OpButton(title: L("terms_accept"), fullWidth: true, action: onAccept)
                    .accessibilityIdentifier("terms.accept")
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
        .background(Zine.paper.ignoresSafeArea())
    }
}

extension AppModel {
    func acceptCurrentTerms() async {
        do { _ = try await prefsRepo.acceptTerms() } catch { toast = uiText(error) }
    }

    func markOnboarded() async {
        _ = try? await prefsRepo.markOnboarded()
    }

    /// A link of oiseaupourri.ch (or an e-mail's): the page it stands for, when the app has it.
    func open(_ url: URL) {
        guard let link = DeepLink.parse(url.absoluteString) else { return }
        switch link {
        case .screen(let screen):
            switch screen {
            case .map: tab = .map
            case .collection: tab = .collection
            case .place: tab = .place
            case .leaderboard: tab = .leaderboard
            case .profile: tab = .profile
            case .settings: push(.settings, on: .profile)
            case .preferences: push(.settings, on: .profile); push(.preferences, on: .profile)
            case .order: push(.order, on: .profile)
            case .orderHistory: push(.orderHistory, on: .profile)
            }
        case .profile(let id):
            push(.profile(userId: id), on: .leaderboard)
        case .account(let landed, let failed):
            accountLanding = AccountLanding(landed: landed, failed: failed)
            push(.settings, on: .profile)
            push(.account, on: .profile)
        case .welcome:
            tab = .map
        case .resetPassword(let token):
            resetToken = token ?? ""
        case .verifyEmail(let token, let landing):
            Task {
                do {
                    _ = try await api.get("/auth/verify-email?token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)", as: Ignored.self)
                    try? await auth.refresh(fresh: true)
                    accountLanding = AccountLanding(landed: landing, failed: false)
                } catch {
                    accountLanding = AccountLanding(landed: nil, failed: true)
                }
                if session.user != nil {
                    push(.settings, on: .profile)
                    push(.account, on: .profile)
                }
            }
        }
    }
}

/// What an e-mail link said when it brought the player to the account page.
struct AccountLanding: Equatable {
    var landed: EmailLanding?
    var failed: Bool
}
