import Foundation
import Testing
@testable import OiseauCore

/// The multipart body as it goes on the wire (Android: OkHttp's MultipartBody).
@MainActor
struct MultipartTests {
    @Test func aFormIsSentAsMultipartWithItsBoundary() async throws {
        let server = ScriptedTransport()
        await server.json(201, #"{"id":"x"}"#)
        var form = MultipartForm(boundary: "B")
        form.add("stickerId", "s1")
        form.add("note", "Plus là")
        form.add("photo", filename: "find.jpg", data: photoBytes)

        let created = try await client(server).postForm("/api/reports", form, as: CreatedResponse.self)

        #expect(created?.id == "x")
        let req = await server.takeRequest()
        #expect(req.method == "POST")
        #expect(req.headers["Content-Type"] == "multipart/form-data; boundary=B")
        #expect(req.headers["Origin"] == nativeAppOrigin)
        let expected = "--B\r\nContent-Disposition: form-data; name=\"stickerId\"\r\n\r\ns1\r\n" +
            "--B\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nPlus là\r\n" +
            "--B\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"find.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n\u{1}\u{2}\u{3}\r\n" +
            "--B--\r\n"
        #expect(text(req.body) == expected)
    }

    @Test func theStubReadsWhatTheClientWrites() {
        var form = MultipartForm()
        form.add("lng", "6.6323")
        form.add("photo", filename: "placement.jpg", data: photoBytes)
        #expect(MultipartForm.fields(of: form.encoded(), contentType: form.contentType) == ["lng": "6.6323", "photo": "placement.jpg"])
    }
}

/// Android: HuntRepositoryTest.
@MainActor
struct HuntRepositoryTests {
    @Test func aFindSendsWhatTheServerChecks() async throws {
        let server = ScriptedTransport()
        await server.json(201, #"{"id":"f1","stickerId":"s1","state":"found"}"#)
        let res = try await HuntRepository(api: client(server), clock: { Date(timeIntervalSince1970: 1_790_000_000) }).find(stickerId: "s1", at: here, photo: photoBytes)

        #expect(res?.id == "f1")
        let req = await server.takeRequest()
        #expect(req.url.path == "/api/finds")
        #expect(req.headers["Content-Type"]?.hasPrefix("multipart/form-data") == true)
        #expect(parts(req) == ["stickerId": "s1", "lng": "6.6323", "lat": "46.5197", "capturedAt": "1790000000000", "photo": "find.jpg"])
    }

    @Test func aReportOmitsABlankNoteAndTheCaptureTime() async throws {
        let server = ScriptedTransport()
        await server.json(201, #"{"id":"r1"}"#)
        try await HuntRepository(api: client(server)).report(stickerId: "s1", at: here, photo: photoBytes, note: "   ")
        let p = parts(await server.takeRequest())
        #expect(p["note"] == nil)
        #expect(p["capturedAt"] == nil)
        #expect(p["photo"] == "report.jpg")

        await server.json(201, #"{"id":"r2"}"#)
        try await HuntRepository(api: client(server)).report(stickerId: "s1", at: here, photo: photoBytes, note: "  plus là  ")
        #expect(parts(await server.takeRequest())["note"] == "plus là")
    }

    @Test func aRefusalCarriesItsCode() async {
        let server = ScriptedTransport()
        await server.json(422, #"{"error":"too_far","message":"You are not close enough to this sticker"}"#)
        let e = await apiError { try await HuntRepository(api: client(server)).find(stickerId: "s1", at: here, photo: photoBytes) }
        #expect(e?.code == "too_far")
    }
}

/// Android: PlaceRepositoryTest.
@MainActor
struct PlaceRepositoryTests {
    private func repo(_ server: ScriptedTransport) -> PlaceRepository {
        let api = client(server)
        return PlaceRepository(api: api, map: MapRepository(api: api))
    }

    private let device = GeoPoint(lng: 6.6323, lat: 46.5197)
    private let target = GeoPoint(lng: 6.6330, lat: 46.5200)

    @Test func aPlacementSendsTheTargetAndTheDeviceSoTheServerCanCheckTheRadius() async throws {
        let server = ScriptedTransport()
        await server.json(201, #"{"id":"s9"}"#)
        await server.json(200, "[]") // the map refetch

        let id = try await repo(server).place(PlacementDraft(point: target, device: device, placeName: " Banc ", hint: "Sous le banc", description: "Vue", isPrivate: true), photo: photoBytes)

        #expect(id == "s9")
        let req = await server.takeRequest()
        #expect(req.url.path == "/api/stickers")
        #expect(parts(req) == [
            "lng": "6.633", "lat": "46.52", "deviceLng": "6.6323", "deviceLat": "46.5197",
            "placeName": "Banc", "hint": "Sous le banc", "description": "Vue", "isPrivate": "1",
            "photo": "placement.jpg",
        ])
        // The new pin is on the map when the player gets back to it.
        #expect(await server.takeRequest().url.path == "/api/map")
    }

    // The server reverse-geocodes an absent name, and coerces ANY non-empty
    // isPrivate ("0", "false" included) to true: absent is the only "no".
    @Test func emptyFieldsAndAPublicSpotAreLeftOut() async throws {
        let server = ScriptedTransport()
        await server.json(201, #"{"id":"s9"}"#)
        await server.json(200, "[]")
        try await repo(server).place(PlacementDraft(point: target, device: device, placeName: "  ", hint: "", description: " ", isPrivate: false), photo: nil)
        #expect(Set(parts(await server.takeRequest()).keys) == ["lng", "lat", "deviceLng", "deviceLat"])
    }

    @Test func aRefusalComesBackWithItsCode() async {
        let server = ScriptedTransport()
        await server.json(400, #"{"error":"too_far_from_device","message":"Placement trop loin de ta position"}"#)
        let e = await apiError { try await repo(server).place(PlacementDraft(point: target, device: device, placeName: "", hint: "", description: "", isPrivate: false), photo: nil) }
        #expect(e?.code == "too_far_from_device")
    }

    @Test func anEditSendsExplicitNulls() async throws {
        let server = ScriptedTransport()
        await server.enqueue(.respond(HttpResponse(status: 204)))
        await server.json(200, "[]")
        let patch = try #require(editPatch(original: device, draft: EditDraft(placeName: "Banc", hint: "", description: "", isPrivate: false, point: device), rules: EditRules(fullEdit: true, canMove: true, minutesLeft: 4)))
        try await repo(server).edit("s9", patch: patch)
        let req = await server.takeRequest()
        #expect(req.method == "PATCH")
        #expect(req.url.path == "/api/stickers/s9")
        #expect(text(req.body) == #"{"description":null,"hint":null,"isPrivate":false,"placeName":"Banc"}"#)
    }

    @Test func autoReadsTheAddressAndTreatsBlankAsNone() async throws {
        let server = ScriptedTransport()
        await server.json(200, #"{"address":"Place Saint-François 15, Lausanne"}"#)
        await server.json(200, #"{"address":""}"#)
        let r = repo(server)
        #expect(try await r.address(at: target) == "Place Saint-François 15, Lausanne")
        #expect(await server.takeRequest().pathAndQuery == "/api/geocode/reverse?lng=6.633&lat=46.52")
        #expect(try await r.address(at: target) == nil)
    }

    // An offline replay: the server deduplicates a placement by its token, and trusts
    // the capture time within FIND_TRUST_WINDOW_MS.
    @Test func aReplaySendsTheTokenAndTheTimeOfTheGesture() async throws {
        let server = ScriptedTransport()
        let api = client(server)
        let sender = ApiQueueSender(api: api, hunt: HuntRepository(api: api, clock: { Date(timeIntervalSince1970: 0.009) }), place: PlaceRepository(api: api, map: MapRepository(api: api)))
        let placement = QueuedAction(
            id: "0b8a7c9e-1d2f-4a3b-9c8d-7e6f5a4b3c2d", userId: "alice", kind: .placement, placeName: "",
            lng: 6.633, lat: 46.52, accuracy: 6, capturedAt: 1_790_000_000_000, deviceLng: 6.6323, deviceLat: 46.5197
        )
        await server.json(200, #"{"id":"s9"}"#) // already in: the bird it made
        await server.json(200, "[]")
        try await sender.send(placement, photo: nil)
        let p = parts(await server.takeRequest())
        #expect(p["clientToken"] == "0b8a7c9e-1d2f-4a3b-9c8d-7e6f5a4b3c2d")
        #expect(p["capturedAt"] == "1790000000000")
        #expect(p["deviceLng"] == "6.6323")
        _ = await server.takeRequest()

        var find = placement
        find.id = "f"
        find.kind = .find
        find.placeName = "Banc"
        find.stickerId = "s1"
        await server.json(201, #"{"id":"f1","stickerId":"s1","state":"found"}"#)
        try await sender.send(find, photo: Data([1]))
        let f = parts(await server.takeRequest())
        // The gesture's time, not the replay's.
        #expect(f["capturedAt"] == "1790000000000")
        #expect(f["stickerId"] == "s1")
        #expect(f["clientToken"] == nil)
    }
}

/// Android: CollectionRepositoryTest.
@MainActor
struct CollectionRepositoryTests {
    private static let route: RoutedTransport.Route = { req in
        switch req.url.path {
        case "/api/collection", "/api/stickers/me", "/api/map": return jsonAnswer("[]")
        default: return HttpResponse(status: 204)
        }
    }

    private func api(_ server: RoutedTransport) -> ApiClient {
        ApiClient(baseURL: testBase, cookieJar: SessionCookieJar(store: MemoryCookieStore()), transport: server, networkUp: { false }, languages: { [] })
    }

    @Test func bothHalvesLoadTogether() async throws {
        let server = RoutedTransport(Self.route)
        let a = api(server)
        let col = try await CollectionRepository(api: a, map: MapRepository(api: a)).load()
        #expect(col.found.isEmpty && col.hidden.isEmpty)
        #expect(col.staleSince == nil)
        #expect(Set(await server.seen) == ["GET /api/collection", "GET /api/stickers/me"])
    }

    // Issue #89: the tab used to show only « Impossible de joindre le serveur ».
    @Test func withoutAServerTheLastCollectionShowsDated() async throws {
        let server = RoutedTransport(Self.route)
        let a = api(server)
        let dir = tempDir("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1))
        let cache = JsonCache(root: dir, userId: { "alice" }, clock: { clock.now })
        _ = try await CollectionRepository(api: a, map: MapRepository(api: a), cache: cache).load()

        await server.close()
        clock.now = Date(timeIntervalSince1970: 9)
        let col = try await CollectionRepository(api: a, map: MapRepository(api: a), cache: cache).load()
        #expect(col.staleSince == Date(timeIntervalSince1970: 1))
        #expect(col.found.isEmpty && col.hidden.isEmpty)
    }

    // `accepted` archives the bird server-side, so the map is refetched after either answer.
    @Test func aReportIsConfirmedOrDismissedByItsStatus() async throws {
        let server = RoutedTransport(Self.route)
        let a = api(server)
        let r = CollectionRepository(api: a, map: MapRepository(api: a))
        try await r.decideReport("r1", accepted: true)
        try await r.decideReport("r2", accepted: false)
        #expect(await server.seen == [
            #"PATCH /api/reports/r1 {"status":"accepted"}"#,
            "GET /api/map",
            #"PATCH /api/reports/r2 {"status":"resolved"}"#,
            "GET /api/map",
        ])
    }

    @Test func theOwnBirdsFindersAndReports() async throws {
        let server = RoutedTransport { req in
            req.url.path.hasSuffix("/finders")
                ? jsonAnswer(#"[{"userId":"u2","displayName":"Bob","foundAt":"2026-10-01T00:00:00Z","findPhotoId":"p"}]"#)
                : jsonAnswer(#"[{"id":"r","reportedById":"u2","reportedByName":"Bob","photoId":"p","createdAt":"2026-10-01T00:00:00Z","status":"open"}]"#)
        }
        let a = api(server)
        let r = CollectionRepository(api: a, map: MapRepository(api: a))
        #expect(try await r.finders("s1").map(\.displayName) == ["Bob"])
        #expect(try await r.reports("s1").map(\.status) == [.open])
    }
}

/// Android: AccountRepositoryTest.
@MainActor
final class AccountRepositoryTests {
    nonisolated private static let zip = Data([0x50, 0x4B, 3, 4, 9, 9])
    private let server = RoutedTransport { req in
        switch req.url.path {
        case "/api/me/export": return HttpResponse(status: 200, body: AccountRepositoryTests.zip)
        case "/auth/get-session": return jsonAnswer(#"{"user":{"id":"u1","email":"a@b.c","name":"Neo"},"session":{"id":"s","userId":"u1","expiresAt":"2026-01-01T00:00:00.000Z"}}"#)
        case "/api/map": return jsonAnswer("[]")
        default: return jsonAnswer("{}")
        }
    }
    private let dir = tempDir("account")
    private let cookies: MemoryCookieStore = {
        let store = MemoryCookieStore()
        store.saved = [StoredCookie(name: "better-auth.session_token", value: "abc", domain: "api.test")]
        return store
    }()
    private lazy var api = ApiClient(baseURL: testBase, cookieJar: SessionCookieJar(store: cookies), transport: server, networkUp: { false }, languages: { [] })
    private lazy var queue = OfflineQueue(dir: dir)
    private lazy var auth = AuthRepository(api: api, userCache: MemoryUserCache())
    private func repo() -> AccountRepository { AccountRepository(api: api, auth: auth, queue: queue, map: MapRepository(api: api)) }

    deinit { try? FileManager.default.removeItem(at: dir) }

    // The API writes the user row itself: Better Auth's cached session would keep the old name.
    @Test func aProfileChangeRereadsTheSessionPastTheCookieCache() async throws {
        try await repo().updateProfile(name: " Neo ", avatar: nil)
        #expect(await server.seen == ["POST /api/profile", "GET /auth/get-session?disableCookieCache=true"])
        #expect(auth.state.user?.name == "Neo")
    }

    @Test func theAuthCallsSendWhatBetterAuthExpects() async throws {
        let r = repo()
        try await r.changePassword(current: "old-password", new: "new-password")
        try await r.changeEmail(" new@example.test ", currentPassword: "old-password")
        try await r.resendVerification(email: "a@b.c")
        #expect(await server.seen == [
            #"POST /auth/change-password {"currentPassword":"old-password","newPassword":"new-password","revokeOtherSessions":true}"#,
            #"POST /auth/change-email {"currentPassword":"old-password","newEmail":"new@example.test"}"#,
            #"POST /auth/send-verification-email {"email":"a@b.c"}"#,
        ])
    }

    @Test func theExportIsKeptAsIs() async throws {
        #expect(try await repo().export() == Self.zip)
    }

    // Parked finds are personal data: their photos must not outlive the account on this phone.
    @Test func deletingTheAccountForgetsWhatTheDeviceHeldForIt() async throws {
        queue.queueFind(userId: "u1", stickerId: "s1", placeName: "Banc", at: here, photo: Data([1]))
        queue.queueFind(userId: "u2", stickerId: "s1", placeName: "Banc", at: here, photo: Data([1]))

        try await repo().deleteAccount(password: "password123", userId: "u1")

        #expect(await server.seen.first == #"POST /auth/delete-user {"password":"password123"}"#)
        #expect(queue.items.map(\.userId) == ["u2"])
        #expect(auth.state == .signedOut)
        #expect(cookies.saved.isEmpty)
    }
}

/// Issue #89: prefs changed without a server were applied, never sent, and gone at the
/// next launch — the placer's charter came back. Now they wait, and survive (Android: PrefsRepositoryTest).
@MainActor
final class PrefsRepositoryTests {
    private let dir = tempDir("prefs")
    private let server = ScriptedTransport()
    private var user: String? = "alice"
    private lazy var api = client(server)
    private lazy var queue = OfflineQueue(dir: dir.appendingPathComponent("q"))
    private var file: URL { dir.appendingPathComponent("prefs.json") }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func repo() -> PrefsRepository {
        PrefsRepository(
            api: api,
            file: file,
            outbox: Outbox(queue: queue, userId: { [unowned self] in user }, knownOffline: { false }, schedule: {}, drainNow: {}),
            pending: { [unowned self] in queue.items },
            userId: { [unowned self] in user }
        )
    }

    private func prefs(_ p: UserPrefs) async throws {
        await server.enqueue(.respond(HttpResponse(status: 200, body: try ApiJson.encoder.encode(p))))
    }

    private func down() async { await server.json(502, "<html>502</html>") }

    @Test func theCharterAcceptedWithoutAServerStaysAcceptedAfterARestart() async throws {
        try await prefs(.newAccount)
        let first = repo()
        try await first.load()
        await down()
        #expect(try await first.acceptPlacementCharter() == .later(.serverDown))
        #expect(queue.items.single?.kind == .prefs)

        // Relaunch with the server still down: the copy on disk.
        let relaunched = repo()
        await down()
        _ = await apiError { try await relaunched.load() }
        #expect(relaunched.prefs?.placementCharterAccepted == true)

        // The server is back but hasn't received it yet: the parked change still shows.
        try await prefs(.newAccount)
        try await relaunched.load()
        #expect(relaunched.prefs?.placementCharterAccepted == true)
    }

    @Test func anotherAccountsSavedPrefsAreNotUsed() async throws {
        var positron = UserPrefs.newAccount
        positron.mapStyle = "positron"
        try await prefs(positron)
        try await repo().load()
        user = "bob"
        let bobs = repo()
        await down()
        _ = await apiError { try await bobs.load() }
        #expect(bobs.prefs == nil)
    }

    @Test func signingOutForgetsThem() async throws {
        try await prefs(.newAccount)
        let r = repo()
        try await r.load()
        #expect(FileManager.default.fileExists(atPath: file.path))
        r.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(r.prefs == nil)
    }

    // Arrays replace wholesale on the server, so the PATCH carries all of them (Android: MapRepositoryTest).
    @Test func revealingASpoilerSendsTheWholeSet() async throws {
        let plain = PrefsRepository(api: api)
        var some = UserPrefs.newAccount
        some.revealedSpoilers = ["a"]
        try await prefs(some)
        try await plain.load()
        _ = await server.takeRequest()

        await server.enqueue(.respond(HttpResponse(status: 204)))
        try await plain.revealSpoiler("b")
        #expect(text(await server.takeRequest().body) == #"{"revealedSpoilers":["a","b"]}"#)

        try await plain.revealSpoiler("b") // already revealed: no request
        #expect(await server.requestCount == 0)
    }

    /// The app assumes `newAccount` is what a new account gets (Android: ContractTest).
    @Test func newAccountPrefsAreTheServersDefaults() throws {
        #expect(try ApiJson.decoder.decode(UserPrefs.self, from: try fixture("prefs-default.json")) == .newAccount)
    }

    @Test func aPatchMergesLikeTheServer() {
        var p = UserPrefs.newAccount
        p.revealedSpoilers = ["a"]
        p.mapStyle = "bright"
        let merged = p.merge(["revealedSpoilers": .array(["b"]), "hideMapSpoilers": true])
        #expect(merged.revealedSpoilers == ["b"]) // arrays replace
        #expect(merged.hideMapSpoilers)
        #expect(merged.mapStyle == "bright") // absent: kept
        #expect(p.merge(nil) == p)
    }
}

/// Issue #89: read screens show their last answer, dated, when nobody answers (Android: JsonCacheTest).
@MainActor
final class JsonCacheTests {
    private let dir = tempDir("jsoncache")
    private var user: String? = "alice"
    private let clock = TestClock(Date(timeIntervalSince1970: 1))
    private lazy var cache = JsonCache(root: dir.appendingPathComponent("cache"), userId: { [unowned self] in user }, clock: { [clock] in clock.now })

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func aFreshAnswerIsShownAndKept() async throws {
        #expect(try await cache.fetch("k") { () async throws(ApiError) in ["a"] } == Fetched(["a"]))
        #expect(cache.get("k", as: [String].self) == Fetched(["a"], staleSince: Date(timeIntervalSince1970: 1)))
    }

    @Test func noAnswerShowsTheLastOneDated() async throws {
        _ = try await cache.fetch("k") { () async throws(ApiError) in ["a"] }
        clock.now = Date(timeIntervalSince1970: 5)
        for down in [ApiError(status: 0, code: ApiError.network), ApiError(status: 502, code: "error")] {
            let got: Fetched<[String]> = try await cache.fetch("k") { () async throws(ApiError) in throw down }
            #expect(got == Fetched(["a"], staleSince: Date(timeIntervalSince1970: 1)))
        }
    }

    @Test func aRefusalIsNotHiddenBehindTheCopy() async throws {
        _ = try await cache.fetch("k") { () async throws(ApiError) in ["a"] }
        let e = await apiError {
            let _: Fetched<[String]> = try await self.cache.fetch("k") { () async throws(ApiError) in throw ApiError(status: 403, code: "forbidden") }
        }
        #expect(e?.code == "forbidden")
    }

    @Test func withNothingKeptTheErrorStillShows() async {
        let e = await apiError {
            let _: Fetched<[String]> = try await self.cache.fetch("k") { () async throws(ApiError) in throw ApiError(status: 0, code: ApiError.network) }
        }
        #expect(e?.code == ApiError.network)
    }

    @Test func eachAccountHasItsOwnAndSignOutForgetsAll() async throws {
        _ = try await cache.fetch("k") { () async throws(ApiError) in ["alice's"] }
        user = "bob"
        #expect(cache.get("k", as: [String].self) == nil)
        cache.clear()
        user = "alice"
        #expect(cache.get("k", as: [String].self) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache").path))
    }
}

/// The write half of the map (Android: MapRepositoryTest).
@MainActor
struct MapRepositoryWriteTests {
    private func map(_ server: ScriptedTransport, _ list: [MapSticker]) async throws {
        await server.enqueue(.respond(HttpResponse(status: 200, body: try ApiJson.encoder.encode(list))))
    }

    private func loaded(_ server: ScriptedTransport, _ s: MapSticker) async throws -> MapRepository {
        let r = MapRepository(api: client(server))
        try await map(server, [s])
        try await r.refresh()
        _ = await server.takeRequest()
        return r
    }

    // Issue #89: a ❤ given without a server is kept, and a refetch before it is sent
    // doesn't take it back on screen.
    @Test func aParkedChangeSurvivesARefetch() async throws {
        let server = ScriptedTransport()
        let dir = tempDir("mapq")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = OfflineQueue(dir: dir)
        let outbox = Outbox(queue: queue, userId: { "alice" }, knownOffline: { false }, schedule: {}, drainNow: {})
        let r = MapRepository(api: client(server), outbox: outbox, pending: { queue.items }, userId: { "alice" })
        var bird = SampleStickers.available
        bird.wishlisted = false
        try await map(server, [bird])
        try await r.refresh()

        await server.json(502, "<html>502 Bad Gateway</html>")
        #expect(try await r.setWishlisted(bird.id, true) == .later(.serverDown))
        try await map(server, [bird]) // the server doesn't have it yet
        try await r.refresh()

        #expect(r.stickers?.single?.wishlisted == true)
        #expect(queue.items.count == 1)
    }

    @Test func wishlistIsOptimisticAndRevertsWhenRefused() async throws {
        let server = ScriptedTransport()
        let r = try await loaded(server, SampleStickers.available)
        await server.json(404, #"{"error":"not_found"}"#)
        var heard: [Bool?] = []
        r.onChange = { heard.append($0?.single?.wishlisted) }

        let e = await apiError { try await r.setWishlisted(SampleStickers.available.id, true) }

        #expect(e?.code == "not_found")
        #expect(sent(await server.takeRequest()) == #"POST /api/wishlist {"stickerId":"s-available"}"#)
        #expect(r.stickers?.single?.wishlisted == false)
        #expect(heard == [true, false]) // shown at once, then reverted
    }

    @Test func removingFromTheWishlistIsADelete() async throws {
        let server = ScriptedTransport()
        var wished = SampleStickers.available
        wished.wishlisted = true
        let r = try await loaded(server, wished)
        await server.enqueue(.respond(HttpResponse(status: 204)))
        try await r.setWishlisted(wished.id, false)
        #expect(sent(await server.takeRequest()) == "DELETE /api/wishlist/s-available")
        #expect(r.stickers?.single?.wishlisted == false)
    }

    // The PATCH must name only what changes: `"hint": null` alongside isPrivate would
    // erase the hint, and — the server counting any text key as an edit, refused 5
    // minutes after placement — turn the toggle into a 403.
    @Test func privateToggleSendsOnlyThatField() async throws {
        let server = ScriptedTransport()
        let r = try await loaded(server, SampleStickers.mine)
        await server.enqueue(.respond(HttpResponse(status: 204)))
        try await r.setPrivate(SampleStickers.mine.id, false)
        #expect(sent(await server.takeRequest()) == #"PATCH /api/stickers/s-mine {"isPrivate":false}"#)
        #expect(r.stickers?.single?.isPrivate == false)
    }

    @Test func archivingRefetchesTheMap() async throws {
        let server = ScriptedTransport()
        let r = try await loaded(server, SampleStickers.mine)
        await server.enqueue(.respond(HttpResponse(status: 204)))
        var archived = SampleStickers.mine
        archived.status = .archived
        try await map(server, [archived])
        try await r.setArchived(SampleStickers.mine.id, true)
        #expect(text(await server.takeRequest().body) == #"{"status":"archived"}"#)
        #expect(await server.takeRequest().url.path == "/api/map")
        #expect(r.stickers?.single?.status == .archived)
    }

    @Test func aDeletionIsShownAtOnceAndARefusalBringsTheBirdBack() async throws {
        let server = ScriptedTransport()
        let r = try await loaded(server, SampleStickers.mine)
        await server.json(403, #"{"error":"forbidden"}"#)
        try await map(server, [SampleStickers.mine]) // the revert refetches
        var heard: [Int?] = []
        r.onChange = { heard.append($0?.count) }
        let e = await apiError { try await r.delete(SampleStickers.mine.id) }
        #expect(e?.code == "forbidden")
        #expect(sent(await server.takeRequest()) == "DELETE /api/stickers/s-mine")
        #expect(heard == [0, 1])
    }

    @Test func anEditIsShownAtOnce() async throws {
        let server = ScriptedTransport()
        let r = try await loaded(server, SampleStickers.mine)
        await server.enqueue(.respond(HttpResponse(status: 204)))
        #expect(try await r.edit(SampleStickers.mine.id, body: ["placeName": "Nouveau nom", "hint": .null]) == .now)
        #expect(r.stickers?.single?.placeName == "Nouveau nom")
        #expect(r.stickers?.single?.hint == nil)
    }
}
