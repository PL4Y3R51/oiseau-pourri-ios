import Foundation
import Observation
import OiseauCore

enum LoginMode { case login, register, forgot }

/// Sign-in / sign-up / forgotten password (Android: LoginViewModel).
@MainActor
@Observable
final class LoginModel {
    var mode: LoginMode {
        didSet {
            if mode != oldValue {
                error = nil
                sent = false
                passwordRuleShown = false
            }
        }
    }
    var name = "" { didSet { error = nil } }
    var email = "" { didSet { error = nil } }
    var password = "" { didSet { error = nil } }
    var termsAccepted = false
    private(set) var busy = false
    private(set) var error: UiText?
    /// Forgot mode: the reset link was requested.
    private(set) var sent = false
    /// A sign-up was refused for a short password: the rule shows until it's met.
    private(set) var passwordRuleShown = false

    /// Better Auth's default minimum (the API doesn't override it).
    static let minPassword = 8

    init(mode: LoginMode) {
        self.mode = mode
    }

    /// The button is disabled until the form makes sense; the password's length is
    /// checked on submit, so the rule is spelled out only once it's broken.
    var canSubmit: Bool {
        guard !busy, !email.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .login: return !password.isEmpty
        case .register: return !name.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && termsAccepted
        case .forgot: return true
        }
    }

    var passwordTooShort: Bool { mode == .register && password.count < Self.minPassword }
    var passwordRuleError: Bool { passwordRuleShown && passwordTooShort }

    func submit(_ app: AppModel) async {
        guard canSubmit else { return }
        if passwordTooShort {
            passwordRuleShown = true
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            switch mode {
            case .login:
                try await app.auth.signIn(email: email, password: password)
            case .register:
                try await app.auth.signUp(name: name, email: email, password: password) { await app.acceptTerms() }
            case .forgot:
                try await app.auth.requestPasswordReset(email: email)
                sent = true
            }
        } catch {
            let fallback = mode == .forgot ? "login_send_failed" : "login_failed"
            self.error = (error as? ApiError).map { authErrorMessage($0, fallback: fallback) } ?? .of(fallback)
        }
    }
}
