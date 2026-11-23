import Foundation

/// Better Auth's user, with the app's `isAdmin` field. `name` is the display name.
public struct AuthUser: Codable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var image: String?
    public var emailVerified: Bool
    public var isAdmin: Bool

    public init(id: String, email: String, name: String, image: String? = nil, emailVerified: Bool = false, isAdmin: Bool = false) {
        self.id = id
        self.email = email
        self.name = name
        self.image = image
        self.emailVerified = emailVerified
        self.isAdmin = isAdmin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        emailVerified = try c.decodeIfPresent(Bool.self, forKey: .emailVerified) ?? false
        isAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
    }
}

public struct SessionInfo: Codable, Hashable, Sendable {
    public var id: String
    public var userId: String
    public var expiresAt: String
}

/// `GET /auth/get-session`: `null` (JSON) when signed out.
public struct AuthSession: Codable, Hashable, Sendable {
    public var user: AuthUser
    public var session: SessionInfo
}

struct SignInRequest: Encodable { var email: String; var password: String }
struct SignUpRequest: Encodable { var email: String; var password: String; var name: String }
struct PasswordResetRequest: Encodable { var email: String; var redirectTo: String }
struct ResetPasswordRequest: Encodable { var newPassword: String; var token: String }

/// Where the player stands. `unknown` only lasts while the stored session is checked.
public enum SessionState: Equatable, Sendable {
    case unknown
    case signedOut
    /// `offline`: the server hasn't confirmed this session yet (unreachable, or not asked yet).
    case signedIn(AuthUser, offline: Bool = false)

    public var user: AuthUser? {
        if case .signedIn(let user, _) = self { return user }
        return nil
    }
}

/// Keeps the last signed-in user so the app opens offline.
public protocol UserCache: AnyObject {
    func load() -> AuthUser?
    func save(_ user: AuthUser?)
}

public final class MemoryUserCache: UserCache {
    public var user: AuthUser?
    public init(_ user: AuthUser? = nil) { self.user = user }
    public func load() -> AuthUser? { user }
    public func save(_ user: AuthUser?) { self.user = user }
}

/// Better Auth e-mail + password, over the web's endpoints (Android: data/AuthRepository.kt).
@MainActor
public final class AuthRepository {
    private let api: ApiClient
    private let userCache: UserCache

    public private(set) var state: SessionState = .unknown {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// The app's model mirrors [state] through this.
    public var onStateChange: ((SessionState) -> Void)?

    public init(api: ApiClient, userCache: UserCache) {
        self.api = api
        self.userCache = userCache
    }

    /// Resolve the stored session at launch. With a session and a last known user the
    /// app opens at once, as that user, and the server confirms behind (issue #89).
    public func restore() async {
        guard api.cookieJar.hasSession(api.baseURL) else {
            userCache.save(nil)
            state = .signedOut
            return
        }
        guard let cached = userCache.load() else {
            // Nobody to open as: only the server can say who this is.
            do { try await refresh() } catch { state = .signedOut }
            return
        }
        state = .signedIn(cached, offline: true)
        await revalidate()
    }

    /// Ask the server about the stored session again. Only its own answer signs out
    /// (no session, or a 401); no answer keeps the last known user, still offline.
    public func revalidate() async {
        do {
            try await refresh()
        } catch {
            if error.isUnauthorized { signedOut() }
        }
    }

    /// Re-read the session (`disableCookieCache`: bypass Better Auth's 5-minute cookie cache).
    public func refresh(fresh: Bool = false) async throws(ApiError) {
        let session = try await api.get("/auth/get-session" + (fresh ? "?disableCookieCache=true" : ""), as: AuthSession.self)
        if let session {
            userCache.save(session.user)
            state = .signedIn(session.user)
        } else {
            signedOut()
        }
    }

    public func signIn(email: String, password: String) async throws(ApiError) {
        _ = try await api.post("/auth/sign-in/email", SignInRequest(email: email.trimmingCharacters(in: .whitespaces), password: password), as: Ignored.self)
        try await refresh()
    }

    /// Sign up; the account is signed in on success (Better Auth's autoSignIn).
    /// [afterSignUp] runs with the new session cookie but BEFORE the app learns it is
    /// signed in, so what it writes (the terms acceptance) is on the server first.
    public func signUp(name: String, email: String, password: String, afterSignUp: () async -> Void = {}) async throws(ApiError) {
        let body = SignUpRequest(
            email: email.trimmingCharacters(in: .whitespaces),
            password: password,
            name: name.trimmingCharacters(in: .whitespaces)
        )
        _ = try await api.post("/auth/sign-up/email", body, as: Ignored.self)
        await afterSignUp()
        try await refresh()
    }

    /// The e-mailed link is the web's /reset-password page.
    public func requestPasswordReset(email: String) async throws(ApiError) {
        let body = PasswordResetRequest(email: email.trimmingCharacters(in: .whitespaces), redirectTo: "/reset-password")
        _ = try await api.post("/auth/request-password-reset", body, as: Ignored.self)
    }

    /// The new password, with the token of the e-mailed `/reset-password?token=…` link.
    /// It signs nobody in (web: ResetPasswordPage).
    public func resetPassword(token: String, newPassword: String) async throws(ApiError) {
        _ = try await api.post("/auth/reset-password", ResetPasswordRequest(newPassword: newPassword, token: token), as: Ignored.self)
    }

    /// Local state is cleared even when the server can't be reached.
    public func signOut() async {
        _ = try? await api.post("/auth/sign-out", EmptyBody(), as: Ignored.self)
        signedOut()
    }

    private func signedOut() {
        api.cookieJar.clear()
        userCache.save(nil)
        state = .signedOut
    }
}
