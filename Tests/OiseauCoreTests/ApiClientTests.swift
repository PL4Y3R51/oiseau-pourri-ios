import Foundation
import Testing
@testable import OiseauCore

/// Translated from Android's ApiClientTest: the wire rules and the session's life.
@MainActor
struct ApiClientTests {
    // Without it Better Auth answers 403 MISSING_OR_NULL_ORIGIN to every
    // cookie-carrying /auth POST.
    @Test func everyRequestCarriesTheNativeOrigin() async throws {
        let server = ScriptedTransport()
        await server.json(200, "{}")
        _ = try await client(server).post("/auth/sign-out", EmptyBody(), as: Ignored.self)
        #expect(await server.takeRequest().headers["Origin"] == nativeAppOrigin)
    }

    @Test func apiErrorsExposeTheirSnakeCaseCode() async {
        let server = ScriptedTransport()
        await server.json(400, #"{"error":"too_far","message":"Trop loin"}"#)
        let api = client(server)
        let e = await apiError { _ = try await api.get("/api/x", as: Ignored.self) }
        #expect(e?.status == 400)
        #expect(e?.code == "too_far")
        #expect(e?.message == "Trop loin")
    }

    @Test func betterAuthErrorsExposeTheirCode() async {
        let server = ScriptedTransport()
        await server.json(401, #"{"code":"INVALID_EMAIL_OR_PASSWORD","message":"Invalid email or password"}"#)
        let api = client(server)
        let e = await apiError { _ = try await api.post("/auth/sign-in/email", SignInRequest(email: "a@b.c", password: "x"), as: Ignored.self) }
        #expect(e?.code == "INVALID_EMAIL_OR_PASSWORD")
        #expect(e.map { authErrorMessage($0, fallback: "login_failed") } == .of("auth_error_credentials"))
    }

    @Test func noServerIsANetworkError() async {
        let server = ScriptedTransport()
        await server.close()
        let api = client(server)
        let e = await apiError { _ = try await api.get("/api/x", as: Ignored.self) }
        #expect(e?.code == ApiError.network)
        // Worded by the app: the transport's own text is technical English.
        #expect(e?.toUiText() == .of("error_network"))
        // A server error is not the player's sign-in failing (issue #89).
        #expect(authErrorMessage(ApiError(status: 500, code: "boom"), fallback: "login_failed") == .of("error_server_down"))
    }

    // Issue #89: nginx answers 502 when the API is down. That is "not now", like no network.
    @Test(arguments: [500, 502, 503, 504])
    func serverErrorsAreUnavailable(status: Int) async {
        let server = ScriptedTransport()
        await server.json(status, "<html>\(status) Bad Gateway</html>")
        let api = client(server)
        let e = await apiError { _ = try await api.get("/api/x", as: Ignored.self) }
        #expect(e?.isUnavailable == true)
        #expect(e?.unavailable == .serverDown)
        #expect(e?.toUiText() == .of("error_server_down"))
    }

    @Test(arguments: [400, 401, 403, 404, 409, 429])
    func refusalsAreNotUnavailable(status: Int) {
        #expect(!ApiError(status: status, code: "x").isUnavailable)
    }

    @Test func noAnswerWithANetworkIsTheServersFault() async {
        let server = ScriptedTransport()
        await server.close()
        let api = client(server, networkUp: true)
        let e = await apiError { _ = try await api.get("/api/x", as: Ignored.self) }
        #expect(e?.code == ApiError.network)
        #expect(e?.unavailable == .serverDown)
    }

    @Test func everyCallTellsWhetherTheServerAnswered() async {
        let server = ScriptedTransport()
        var seen: [Bool] = []
        let api = client(server)
        api.onServerAnswered = { seen.append($0) }
        await server.json(404, #"{"error":"not_found"}"#)
        _ = try? await api.get("/api/x", as: Ignored.self)
        await server.json(502, "")
        _ = try? await api.get("/api/x", as: Ignored.self)
        await server.close()
        _ = try? await api.get("/api/x", as: Ignored.self)
        // A refusal is an answer; a 502 and silence are not.
        #expect(seen == [true, false, false])
    }

    // A stuck API used to hold a find's spinner for the 30 s read timeout.
    @Test func aGestureGivesUpOnAStuckServer() async {
        let server = ScriptedTransport()
        await server.enqueue(.hang(5, HttpResponse(status: 200, json: "{}")))
        let api = client(server)
        let started = Date()
        let e = await apiError { _ = try await api.send("POST", "/api/finds", body: Data("{}".utf8), timeout: 0.3) }
        #expect(e?.isUnavailable == true)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func serverMessagesAreShownAsTheyCame() {
        #expect(ApiError(status: 404, code: "not_found", message: "Sticker introuvable").toUiText() == .raw("Sticker introuvable"))
        #expect(ApiError(status: 404, code: "not_found").toUiText() == .raw("not_found"))
    }

    @Test func everyRequestCarriesThePlayersLanguages() async throws {
        let server = ScriptedTransport()
        await server.json(200, "{}")
        _ = try await client(server, languages: ["de-CH", "fr-CH"]).get("/api/x", as: Ignored.self)
        #expect(await server.takeRequest().headers["Accept-Language"] == "de-CH, fr-CH;q=0.9")
    }

    @Test func acceptLanguageRanksAndCleansTheList() {
        #expect(acceptLanguage(["fr-CH", " en-US", "de", "fr-CH", "und", ""]) == "fr-CH, en-US;q=0.9, de;q=0.8")
        #expect(acceptLanguage([]) == "")
    }

    @Test func emptyBodyDecodesToNil() async throws {
        let server = ScriptedTransport()
        await server.enqueue(.respond(HttpResponse(status: 204)))
        #expect(try await client(server).patch("/api/me/prefs", EmptyBody(), as: Ignored.self) == nil)
    }

    @Test func aJsonBodyIsTheSameBytesEveryTime() async throws {
        let server = ScriptedTransport()
        await server.json(200, "{}")
        _ = try await client(server).post("/api/wishlist", AddWishlistBody(stickerId: "s-available"), as: Ignored.self)
        let req = await server.takeRequest()
        #expect(text(req.body) == #"{"stickerId":"s-available"}"#)
        #expect(req.headers["Content-Type"] == "application/json")
    }

    @Test func theSessionCookieSurvivesARestartAndIsReplayed() async throws {
        let server = ScriptedTransport()
        let store = MemoryCookieStore()
        await server.json(200, "{}", cookies: [sessionCookie])
        _ = try await client(server, store: store).post("/auth/sign-in/email", SignInRequest(email: "a@b.c", password: "x"), as: Ignored.self)
        #expect(await server.takeRequest().headers["Cookie"] == nil)

        // A brand-new client over the same store = the app after a relaunch.
        let relaunched = client(server, store: store)
        #expect(relaunched.cookieJar.hasSession(relaunched.baseURL))
        await server.json(200, "{}")
        _ = try await relaunched.get("/api/profile", as: Ignored.self)
        #expect(await server.takeRequest().headers["Cookie"] == "better-auth.session_token=abc.sig")
    }

    @Test func anExpiredSetCookieDeletesTheCookie() async throws {
        let server = ScriptedTransport()
        let api = client(server)
        await server.json(200, "{}", cookies: [sessionCookie])
        _ = try await api.get("/api/x", as: Ignored.self)
        await server.json(200, "{}", cookies: ["better-auth.session_token=; Max-Age=0; Path=/"])
        _ = try await api.get("/api/x", as: Ignored.self)
        #expect(!api.cookieJar.hasSession(api.baseURL))
    }
}

/// The session at launch and sign-out (also from Android's ApiClientTest).
@MainActor
struct AuthRepositoryTests {
    private let alice = AuthUser(id: "id", email: "a@b.c", name: "A")

    /// A client whose jar holds a session, as after a sign-in.
    private func signedIn(_ server: ScriptedTransport, store: MemoryCookieStore = MemoryCookieStore()) async throws -> ApiClient {
        let api = client(server, store: store)
        await server.json(200, "{}", cookies: [sessionCookie])
        _ = try await api.post("/auth/sign-in/email", SignInRequest(email: "a@b.c", password: "x"), as: Ignored.self)
        _ = await server.takeRequest()
        return api
    }

    @Test func signOutForgetsTheSessionEvenOffline() async throws {
        let server = ScriptedTransport()
        let store = MemoryCookieStore()
        let api = try await signedIn(server, store: store)
        let cache = MemoryUserCache(alice)
        let auth = AuthRepository(api: api, userCache: cache)

        await server.close() // sign-out can't reach the server
        await auth.signOut()

        #expect(!api.cookieJar.hasSession(api.baseURL))
        #expect(store.saved.isEmpty)
        #expect(cache.user == nil)
        #expect(auth.state == .signedOut)
    }

    @Test func restoreOfflineFallsBackToTheCachedUser() async throws {
        let server = ScriptedTransport()
        let auth = AuthRepository(api: try await signedIn(server), userCache: MemoryUserCache(alice))
        await server.close()
        await auth.restore()
        #expect(auth.state == .signedIn(alice, offline: true))
    }

    // Issue #89: a 502 at launch read as "signed out". Only the server's own answer signs out.
    @Test func restoreWhileTheServerIsDownKeepsTheCachedUser() async throws {
        let server = ScriptedTransport()
        let api = try await signedIn(server)
        let auth = AuthRepository(api: api, userCache: MemoryUserCache(alice))
        await server.json(502, "<html>502 Bad Gateway</html>")
        await auth.restore()
        #expect(auth.state == .signedIn(alice, offline: true))
        #expect(api.cookieJar.hasSession(api.baseURL))
    }

    // Issue #89: a stuck API held the splash for the whole read timeout.
    @Test func restoreOpensAsTheCachedUserBeforeTheServerAnswers() async throws {
        let server = ScriptedTransport()
        let auth = AuthRepository(api: try await signedIn(server), userCache: MemoryUserCache(alice))
        await server.enqueue(.hang(5, HttpResponse(status: 200, json: "null")))

        let restoring = Task { await auth.restore() }
        for _ in 0..<50 where auth.state == .unknown { await Task.yield() }

        #expect(auth.state == .signedIn(alice, offline: true))
        restoring.cancel()
    }

    @Test func aRevokedSessionStillSignsOutAfterOpeningFromCache() async throws {
        let server = ScriptedTransport()
        let api = try await signedIn(server)
        let auth = AuthRepository(api: api, userCache: MemoryUserCache(alice))
        await server.json(200, "null") // get-session: the server no longer knows this session
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(!api.cookieJar.hasSession(api.baseURL))
    }

    @Test func a401AlsoSignsOut() async throws {
        let server = ScriptedTransport()
        let auth = AuthRepository(api: try await signedIn(server), userCache: MemoryUserCache(alice))
        await server.json(401, #"{"error":"Authentication required"}"#)
        await auth.restore()
        #expect(auth.state == .signedOut)
    }

    @Test func restoreWithARevokedSessionAndNoCacheSignsOut() async throws {
        let server = ScriptedTransport()
        let api = try await signedIn(server)
        await server.json(200, "null")
        let auth = AuthRepository(api: api, userCache: MemoryUserCache())
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(!api.cookieJar.hasSession(api.baseURL))
    }

    @Test func noSessionCookieIsSignedOutWithoutAsking() async {
        let server = ScriptedTransport()
        let auth = AuthRepository(api: client(server), userCache: MemoryUserCache(alice))
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(await server.requestCount == 0)
    }

    // The sign-up checkbox's terms acceptance must be on the server before the app
    // learns it is signed in, or the terms gate pops up over the new account.
    @Test func signUpRunsItsHookBeforeAnnouncingTheSession() async throws {
        let server = ScriptedTransport()
        await server.json(200, "{}", cookies: [sessionCookie])
        await server.json(200, #"{"user":{"id":"u","email":"a@b.c","name":"A"},"session":{"id":"s","userId":"u","expiresAt":"2026-01-01T00:00:00.000Z"}}"#)
        let auth = AuthRepository(api: client(server), userCache: MemoryUserCache())
        var stateDuringHook: SessionState?

        try await auth.signUp(name: "A", email: "a@b.c", password: "password123") { stateDuringHook = auth.state }

        #expect(stateDuringHook == .unknown)
        #expect(auth.state.user?.id == "u")
    }

    @Test func signInTrimsTheEmailAndReadsTheSession() async throws {
        let server = ScriptedTransport()
        await server.json(200, "{}", cookies: [sessionCookie])
        await server.json(200, #"{"user":{"id":"u","email":"a@b.c","name":"A"},"session":{"id":"s","userId":"u","expiresAt":"2026-01-01T00:00:00.000Z"}}"#)
        let cache = MemoryUserCache()
        let auth = AuthRepository(api: client(server), userCache: cache)
        try await auth.signIn(email: " a@b.c ", password: "pw")
        #expect(text(await server.takeRequest().body) == #"{"email":"a@b.c","password":"pw"}"#)
        #expect(auth.state == .signedIn(AuthUser(id: "u", email: "a@b.c", name: "A")))
        #expect(cache.user?.id == "u")
    }
}
