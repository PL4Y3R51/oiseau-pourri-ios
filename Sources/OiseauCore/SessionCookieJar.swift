import Foundation

/// One cookie as kept between launches.
public struct StoredCookie: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    /// The host it was set by, or its `Domain` attribute without the leading dot.
    public var domain: String
    /// No `Domain` attribute: only that exact host gets it back.
    public var hostOnly: Bool
    public var path: String
    /// `nil`: a session cookie, kept anyway (a phone app has no browser session to end).
    public var expiresAt: Date?
    public var secure: Bool

    public init(name: String, value: String, domain: String, hostOnly: Bool = true, path: String = "/", expiresAt: Date? = nil, secure: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = hostOnly
        self.path = path
        self.expiresAt = expiresAt
        self.secure = secure
    }

    func isExpired(_ now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }

    func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let hostOk = hostOnly ? host == domain : (host == domain || host.hasSuffix("." + domain))
        let path = url.path.isEmpty ? "/" : url.path
        let pathOk = path == self.path || path.hasPrefix(self.path.hasSuffix("/") ? self.path : self.path + "/")
        return hostOk && pathOk && (!secure || url.scheme == "https")
    }

    /// One `Set-Cookie` header, as the API sends it (RFC 6265, the parts Better Auth uses).
    public static func parse(_ header: String, from url: URL, now: Date = Date()) -> StoredCookie? {
        let parts = header.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return nil }
        let name = String(first[..<eq]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let host = url.host?.lowercased() else { return nil }
        var cookie = StoredCookie(name: name, value: String(first[first.index(after: eq)...]), domain: host)
        var maxAge: Date?
        var expires: Date?
        for attr in parts.dropFirst() {
            let kv = attr.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            let key = kv[0].lowercased()
            let value = kv.count > 1 ? kv[1] : ""
            switch key {
            case "max-age":
                if let seconds = Int(value) { maxAge = seconds <= 0 ? Date.distantPast : now.addingTimeInterval(TimeInterval(seconds)) }
            case "expires":
                expires = parseHttpDate(value)
            case "domain":
                let d = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                // A server may only set cookies for itself or a parent domain of it.
                guard !d.isEmpty, host == d || host.hasSuffix("." + d) else { return nil }
                cookie.domain = d
                cookie.hostOnly = false
            case "path":
                if value.hasPrefix("/") { cookie.path = value }
            case "secure":
                cookie.secure = true
            default:
                break
            }
        }
        cookie.expiresAt = maxAge ?? expires
        return cookie
    }
}

private func parseHttpDate(_ text: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        f.dateFormat = format
        if let d = f.date(from: text) { return d }
    }
    return nil
}

/// Where the jar keeps its cookies between launches: the Keychain in the app.
public protocol CookieStore: AnyObject {
    func load() -> [StoredCookie]
    func save(_ cookies: [StoredCookie])
}

public final class MemoryCookieStore: CookieStore {
    public var saved: [StoredCookie] = []
    public init() {}
    public func load() -> [StoredCookie] { saved }
    public func save(_ cookies: [StoredCookie]) { saved = cookies }
}

/// The Better Auth session, carried the way a browser would: the API sets
/// `better-auth.session_token` (and the 5-minute `session_data` cache) as cookies,
/// and the app replays them on every `/auth` and `/api` call — the API has no
/// bearer-token mode. Persisted so the player stays signed in.
@MainActor
public final class SessionCookieJar {
    private let store: CookieStore
    private let clock: () -> Date
    private var cookies: [StoredCookie]?

    public init(store: CookieStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    private var all: [StoredCookie] {
        get {
            if let cookies { return cookies }
            let loaded = store.load()
            cookies = loaded
            return loaded
        }
        set {
            cookies = newValue
            store.save(newValue)
        }
    }

    public func save(_ headers: [String], from url: URL) {
        guard !headers.isEmpty else { return }
        let now = clock()
        var jar = all
        for header in headers {
            guard let c = StoredCookie.parse(header, from: url, now: now) else { continue }
            jar.removeAll { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            // An expired Set-Cookie is how the server deletes one (sign-out).
            if !c.isExpired(now) { jar.append(c) }
        }
        all = jar
    }

    public func cookies(for url: URL) -> [StoredCookie] {
        let now = clock()
        var jar = all
        if jar.contains(where: { $0.isExpired(now) }) {
            jar.removeAll { $0.isExpired(now) }
            all = jar
        }
        return jar.filter { $0.matches(url) }
    }

    /// The `Cookie` header for a request, or nil when there is nothing to send.
    public func header(for url: URL) -> String? {
        let list = cookies(for: url)
        return list.isEmpty ? nil : list.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// True when a session cookie is stored (the player was signed in).
    public func hasSession(_ url: URL) -> Bool {
        cookies(for: url).contains { $0.name.hasSuffix(SessionCookieJar.sessionToken) }
    }

    public func clear() {
        all = []
    }

    /// Under https Better Auth prefixes it with `__Secure-`.
    public static let sessionToken = "better-auth.session_token"
}
