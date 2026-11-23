import Foundation

/// A text for the player: a key of Localizable.xcstrings (the Android string names),
/// or the server's own words. Resolved by the app; compared as-is in tests.
public enum UiText: Equatable, Sendable {
    case key(String, args: [String] = [])
    case raw(String)

    public static func of(_ key: String, _ args: String...) -> UiText { .key(key, args: args) }
}

/// Why the server couldn't be asked. Both are "not now" for the game (issue #89),
/// worded apart for the player.
public enum Unavailable: Sendable, Equatable {
    case noNetwork
    case serverDown
}

/// A failed call (Android: ApiException). [code] is the API's snake_case `error`,
/// Better Auth's UPPER_SNAKE `code`, or [ApiError.network] when nothing answered.
public struct ApiError: Error, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String?
    public let unavailable: Unavailable?

    public init(status: Int, code: String, message: String? = nil, unavailable: Unavailable?? = .none) {
        self.status = status
        self.code = code
        self.message = message
        switch unavailable {
        case .none: self.unavailable = ApiError.unavailableFor(status: status, code: code)
        case .some(let given): self.unavailable = given
        }
    }

    public var isUnauthorized: Bool { status == 401 }

    /// No network, or a server that doesn't answer properly (5xx, timeout): not a refusal.
    public var isUnavailable: Bool { unavailable != nil }

    public func toUiText() -> UiText {
        switch unavailable {
        case .noNetwork: return .of("error_network")
        case .serverDown: return .of("error_server_down")
        case nil: return .raw(message ?? code)
        }
    }

    public static let network = "network"
    public static let unknown = "error"

    public static func unavailableFor(status: Int, code: String) -> Unavailable? {
        if code == network { return .noNetwork }
        if status >= 500 { return .serverDown }
        return nil
    }

    /// Both error shapes the server answers with: `/api` sends `{error, message?}`,
    /// Better Auth's `/auth` sends `{code, message}`.
    public static func from(status: Int, body: Data) -> ApiError {
        let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body)
        let code = decoded?.error ?? decoded?.code ?? (status == 429 ? "RATE_LIMITED" : unknown)
        return ApiError(status: status, code: code, message: decoded?.message)
    }
}

struct ErrorBody: Decodable {
    var error: String?
    var code: String?
    var message: String?
}

/// The message for a failed auth call. Better Auth's own messages are English;
/// the app words the codes a player can hit.
public func authErrorMessage(_ e: ApiError, fallback: String) -> UiText {
    if e.isUnavailable { return e.toUiText() }
    switch e.code {
    case "INVALID_EMAIL_OR_PASSWORD": return .of("auth_error_credentials")
    case "INVALID_PASSWORD", "PASSWORD_REQUIRED": return .of("auth_error_password")
    case "USER_ALREADY_EXISTS", "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL": return .of("auth_error_exists")
    case "INVALID_EMAIL": return .of("auth_error_email")
    case "PASSWORD_TOO_SHORT": return .of("auth_error_short")
    case "PASSWORD_TOO_LONG": return .of("auth_error_long")
    case "RATE_LIMITED": return .of("auth_error_rate")
    // An e-mailed link used twice, too late, or for an account that is gone.
    case "INVALID_TOKEN", "TOKEN_EXPIRED", "USER_NOT_FOUND", "INVALID_USER": return .of("auth_error_link")
    default: return .of(fallback)
    }
}
