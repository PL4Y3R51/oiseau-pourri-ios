import SwiftUI
import OiseauCore

/// The signed-out part: the welcome carousel, and the sign-in behind it.
struct SignedOutFlow: View {
    @State private var path: [LoginMode] = []

    init() {}

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(onLogin: { path.append(.login) })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: LoginMode.self) { mode in
                    LoginView(model: LoginModel(mode: mode))
                }
        }
    }
}

/// Sign-in / sign-up / forgot, one mascot mood per mode (Android: LoginScreen).
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var model: LoginModel

    init(model: LoginModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let sent = model.mode == .forgot && model.sent
        let (pose, kicker, title): (MascottePose, String, String) = {
            switch model.mode {
            case .login: return (.celebrate, L("login_kicker"), L("login_title"))
            case .register: return (.wave, L("welcome_hunt_kicker"), L("welcome_hunt_title"))
            case .forgot: return (sent ? .wave : .sad, L("forgot_kicker"), L("forgot_title"))
            }
        }()
        ScrollView {
            VStack(spacing: 12) {
                AuthHeader(pose: pose, kicker: kicker, title: title)
                Spacer().frame(height: 4)
                if sent {
                    Text(L("login_reset_sent", model.email.trimmingCharacters(in: .whitespaces)))
                        .font(.zBodyLarge)
                        .foregroundStyle(Zine.ink)
                        .multilineTextAlignment(.center)
                } else {
                    LoginForm(model: model)
                }
                if model.mode == .login {
                    LinkButton(title: L("login_forgot")) { model.mode = .forgot }
                        .accessibilityIdentifier("login.forgot")
                }
                LinkButton(title: L(model.mode == .login ? "login_to_register" : model.mode == .register ? "login_to_login" : "login_back")) {
                    model.mode = model.mode == .login ? .register : .login
                }
                .accessibilityIdentifier("login.switch")
            }
            .frame(maxWidth: 480)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Zine.paper.ignoresSafeArea())
    }
}

/// The fields and the button of a mode; the carousel's last page reuses the sign-up one.
struct LoginForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Bindable var model: LoginModel
    var submitLabel: String?

    init(model: LoginModel, submitLabel: String? = nil) {
        self.model = model
        self.submitLabel = submitLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.mode == .register {
                OpTextField(label: L("login_name"), text: $model.name, kind: .name, identifier: "login.name")
            }
            OpTextField(
                label: L("login_email"), text: $model.email, kind: .email,
                submitLabel: model.mode == .forgot ? .send : .next,
                identifier: "login.email",
                onSubmit: { if model.mode == .forgot { submit() } }
            )
            if model.mode != .forgot {
                OpTextField(
                    label: L("login_password"), text: $model.password,
                    kind: model.mode == .login ? .password : .newPassword,
                    supporting: model.passwordRuleError ? L("login_password_hint") : nil,
                    isError: model.passwordRuleError,
                    submitLabel: .go,
                    identifier: "login.password",
                    onSubmit: submit
                )
            }
            if model.mode == .register {
                HStack(alignment: .center, spacing: 0) {
                    ZineCheckbox(isOn: $model.termsAccepted, label: L("login_accept_terms", L("legal_terms_link"), L("legal_privacy_link")))
                        .accessibilityIdentifier("login.terms")
                    Text(termsText)
                        .font(.zBody)
                        .foregroundStyle(Zine.ink)
                        .environment(\.openURL, OpenURLAction { url in
                            openURL(url)
                            return .handled
                        })
                }
            }
            if let error = model.error {
                Text(error.text).font(.zBody).foregroundStyle(Zine.error)
                    .accessibilityIdentifier("login.error")
            }
            OpButton(title: buttonTitle, fullWidth: true, action: submit)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("login.submit")
        }
    }

    private var buttonTitle: String {
        if model.busy { return L("login_busy") }
        if let submitLabel { return submitLabel }
        switch model.mode {
        case .login: return L("login_submit_login")
        case .register: return L("login_submit_register")
        case .forgot: return L("login_submit_forgot")
        }
    }

    /// « J'accepte les conditions d'utilisation et la politique de confidentialité. », both links.
    private var termsText: AttributedString {
        let terms = L("legal_terms_link")
        let privacy = L("legal_privacy_link")
        var text = AttributedString(L("login_accept_terms", terms, privacy))
        for (part, doc) in [(terms, LegalDoc.cgu), (privacy, LegalDoc.privacy)] {
            if let range = text.range(of: part) {
                text[range].link = doc.url
                text[range].underlineStyle = .single
            }
        }
        return text
    }

    private func submit() {
        Task { await model.submit(app) }
    }
}
