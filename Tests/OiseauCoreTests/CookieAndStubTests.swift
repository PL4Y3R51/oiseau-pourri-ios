import Foundation
import Testing
@testable import OiseauCore

struct CookieTests {
    private let url = URL(string: "https://oiseaupourri.ch/api/map")!

    // URLSession folds repeated Set-Cookie headers into one, comma-joined.
    @Test func aFoldedHeaderSplitsBackIntoItsCookies() {
        let folded = "__Secure-better-auth.session_token=abc.sig; Max-Age=604800; Path=/; HttpOnly; Secure, " +
            "__Secure-better-auth.session_data=xyz; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; Secure"
        let parts = splitSetCookieHeader(folded)
        #expect(parts.count == 2)
        #expect(parts[1].hasPrefix("__Secure-better-auth.session_data=xyz"))
        #expect(parts[1].contains("Wed, 21 Oct 2026"))
    }

    @Test func parsesWhatBetterAuthSends() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let c = try #require(StoredCookie.parse("__Secure-better-auth.session_token=abc.sig; Max-Age=60; Path=/; HttpOnly; Secure; SameSite=Lax", from: url, now: now))
        #expect(c.name == "__Secure-better-auth.session_token")
        #expect(c.value == "abc.sig")
        #expect(c.domain == "oiseaupourri.ch")
        #expect(c.hostOnly)
        #expect(c.secure)
        #expect(c.expiresAt == now.addingTimeInterval(60))
        // Secure: never sent over http.
        #expect(c.matches(url))
        #expect(!c.matches(URL(string: "http://oiseaupourri.ch/api/map")!))
    }

    @Test func expiresIsReadWhenThereIsNoMaxAge() throws {
        let c = try #require(StoredCookie.parse("a=b; Expires=Wed, 21 Oct 2026 07:28:00 GMT", from: url))
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_792_567_680))
    }

    @Test func aCookieStaysWithItsHostAndPath() throws {
        let c = try #require(StoredCookie.parse("a=b; Path=/api", from: url))
        #expect(c.matches(URL(string: "https://oiseaupourri.ch/api/x")!))
        #expect(!c.matches(URL(string: "https://oiseaupourri.ch/apix")!))
        #expect(!c.matches(URL(string: "https://admin.oiseaupourri.ch/api/x")!))
        // A server can't set a cookie for somebody else.
        #expect(StoredCookie.parse("a=b; Domain=evil.test", from: url) == nil)
    }
}

/// The stub the app runs against in CI must behave like the real API where the app looks.
@MainActor
struct StubServerTests {
    private func app(_ stub: StubServer, cache: MemoryUserCache = MemoryUserCache(), store: MemoryCookieStore = MemoryCookieStore()) -> (AuthRepository, MapRepository) {
        let api = ApiClient(baseURL: testBase, cookieJar: SessionCookieJar(store: store), transport: stub)
        return (AuthRepository(api: api, userCache: cache), MapRepository(api: api))
    }

    @Test func signInThenTheMap() async throws {
        let (auth, map) = app(StubServer(latency: 0))
        await auth.restore()
        #expect(auth.state == .signedOut)
        let wrong = await apiError { try await auth.signIn(email: StubServer.email, password: "nope") }
        #expect(wrong?.code == "INVALID_EMAIL_OR_PASSWORD")
        try await auth.signIn(email: StubServer.email, password: StubServer.password)
        #expect(auth.state.user?.email == StubServer.email)
        try await map.refresh()
        #expect(map.stickers?.count == SampleStickers.all.count)
        await auth.signOut()
        #expect(auth.state == .signedOut)
        #expect(await apiError { try await map.refresh() }?.isUnauthorized == true)
    }

    @Test func aDownStubKeepsTheCachedPlayer() async throws {
        let store = MemoryCookieStore()
        let cache = MemoryUserCache()
        let (auth, _) = app(StubServer(latency: 0), cache: cache, store: store)
        try await auth.signIn(email: StubServer.email, password: StubServer.password)
        let player = try #require(cache.user)

        let (relaunched, _) = app(StubServer(mode: .serverDown, latency: 0), cache: cache, store: store)
        await relaunched.restore()
        #expect(relaunched.state == .signedIn(player, offline: true))
    }
}
