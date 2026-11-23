import Foundation
import Testing
@testable import OiseauCore

/// Issue #89: no network and no server are one state for the game, worded apart (Android: ReachabilityTest).
@MainActor
struct ReachabilityTests {
    @Test func theNetworkComesFirst() {
        #expect(reachOf(network: true, serverAnswers: true) == .online)
        #expect(reachOf(network: true, serverAnswers: false) == .serverDown)
        // Without a network, nothing is known about the server: it's the signal.
        #expect(reachOf(network: false, serverAnswers: false) == .noNetwork)
        #expect(reachOf(network: false, serverAnswers: true) == .noNetwork)
    }

    @Test func aServerThatStopsAnsweringIsDownUntilItAnswersAgain() {
        let r = Reachability(networkUp: true)
        r.serverAnswered(false)
        #expect(r.state == .serverDown)
        r.serverAnswered(true)
        #expect(r.state == .online)
    }

    // A failed call in a tunnel says nothing about the server: when the signal is
    // back, the banner must not claim « Le serveur ne répond pas ».
    @Test func failuresWithoutANetworkDontBlameTheServer() {
        let r = Reachability(networkUp: false)
        r.serverAnswered(false)
        #expect(r.state == .noNetwork)
        r.networkChanged(true)
        #expect(r.state == .online)
    }

    // Closed once, the band stays closed for this outage, and opens in full for the next.
    @Test func aClosedBandStaysClosedUntilTheServerIsBack() {
        let r = Reachability()
        r.serverAnswered(false)
        r.closeBand(true)
        #expect(r.bandClosed)
        r.serverAnswered(false)
        #expect(r.bandClosed)
        r.serverAnswered(true)
        #expect(!r.bandClosed)
    }

    @Test func aNetworkComingBackGivesTheServerTheBenefitOfTheDoubt() {
        let r = Reachability()
        r.serverAnswered(false)
        r.networkChanged(false)
        #expect(r.state == .noNetwork)
        r.networkChanged(true)
        // The app probes at once; until then, don't guess it's down.
        #expect(r.state == .online)
    }

    @Test func listenersHearEachChangeOnce() {
        let r = Reachability()
        var heard: [Reach] = []
        r.onChange = { heard.append($0) }
        r.serverAnswered(false)
        r.serverAnswered(false)
        r.networkChanged(false)
        r.networkChanged(true)
        #expect(heard == [.serverDown, .noNetwork, .online])
    }
}

/// The drain's driver (Android: sync/OfflineSync.kt, which has no test of its own).
@MainActor
final class OfflineSyncTests {
    private let dir = tempDir("sync")
    private lazy var queue = OfflineQueue(dir: dir)
    private var user: String? = "alice"
    private var schedules = 0

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func sync(_ sender: FakeSender) -> OfflineSync {
        OfflineSync(queue: queue, sender: sender, userId: { [unowned self] in user }, schedule: { [unowned self] in schedules += 1 })
    }

    @Test func nobodySignedInDrainsNothing() async {
        user = nil
        queue.queueFind(userId: "alice", stickerId: "s1", placeName: "Banc", at: here, photo: photoBytes)
        let sender = FakeSender()
        #expect(await sync(sender).drain() == nil)
        #expect(sender.sent.isEmpty)
    }

    @Test func aLandingIsAnnouncedForTheMap() async {
        queue.queueFind(userId: "alice", stickerId: "s1", placeName: "Banc", at: here, photo: photoBytes)
        let s = sync(FakeSender())
        var landed: [Int] = []
        s.onLanded = { landed.append($0) }
        #expect(await s.drain() == DrainResult(landed: 1, stillPending: false))
        #expect(landed == [1])
        #expect(schedules == 0)
    }

    // A refusal is announced too: what was shown before it was sent must be refetched to undo it.
    @Test func aRefusalIsAnnouncedToo() async {
        queue.queueChange(userId: "alice", kind: .wishlist, stickerId: "s1", payload: ["on": true])
        let s = sync(FakeSender { _ in ApiError(status: 403, code: "forbidden") })
        var landed: [Int] = []
        s.onLanded = { landed.append($0) }
        await s.drain()
        #expect(landed == [0])
    }

    @Test func stillPendingAsksToBeWokenAgain() async {
        queue.queueFind(userId: "alice", stickerId: "s1", placeName: "Banc", at: here, photo: photoBytes)
        let s = sync(FakeSender { _ in ApiError(status: 0, code: ApiError.network) })
        #expect(await s.drain()?.stillPending == true)
        #expect(schedules == 1)
        s.scheduleIfPending()
        #expect(schedules == 2)
    }

    @Test func nothingPendingSchedulesNothing() {
        sync(FakeSender()).scheduleIfPending()
        #expect(schedules == 0)
    }
}

@MainActor
final class FakeZones: OfflineZoneStore {
    var zones: [OfflineZone] = []
    var deleted: [String] = []
    var downloaded: [(ZoneMeta, GeoBounds, Int)] = []

    func list() async -> [OfflineZone] { zones }
    func delete(_ id: String) async { deleted.append(id) }
    func download(_ meta: ZoneMeta, styleURL: URL, bounds: GeoBounds, maxZoom: Int) async throws { downloaded.append((meta, bounds, maxZoom)) }
}

/// The « Autour de chez toi » zone's decisions (Android: sync/AutoZone.kt, which has no test of its own).
@MainActor
struct AutoZoneTests {
    private let lausanne = GeoPoint(lng: 6.6323, lat: 46.5197)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func auto(_ store: FakeZones, enabled: Bool = true, samples: [GeoPoint]? = nil, style: MapStyle = .liberty) -> AutoZone {
        AutoZone(enabled: { enabled }, homeSamples: { [lausanne] in samples ?? [lausanne, lausanne, lausanne] }, mapStyle: { style }, store: store, clock: { [now] in now })
    }

    private func zone(_ id: String, kind: ZoneKind, center: GeoPoint? = nil, ageDays: Int = 1, style: String = "liberty", bytes: Int64 = 1) -> OfflineZone {
        OfflineZone(id: id, meta: ZoneMeta(name: id, kind: kind, styleId: style, createdAt: epochMs(now) - Int64(ageDays) * 86_400_000, centerLng: center?.lng, centerLat: center?.lat), bytes: bytes)
    }

    @Test func theFirstZoneIsDownloadedAroundHome() async throws {
        let store = FakeZones()
        #expect(try await auto(store).run() == .download)
        let (meta, bounds, maxZoom) = try #require(store.downloaded.single)
        #expect(meta.kind == .auto)
        #expect(meta.center == lausanne)
        #expect(meta.styleId == "liberty")
        #expect(bounds == boundsAround(lausanne, radiusM: autoZoneRadiusM))
        #expect(maxZoom == 16)
    }

    @Test func offOrWithoutAHomeNothingHappens() async throws {
        let store = FakeZones()
        #expect(try await auto(store, enabled: false).run() == .nothing)
        #expect(try await auto(store, samples: [lausanne]).run() == .nothing)
        #expect(store.downloaded.isEmpty)
    }

    @Test func aFreshZoneAtHomeIsKept() async throws {
        let store = FakeZones()
        store.zones = [zone("a", kind: .auto, center: lausanne)]
        #expect(try await auto(store).run() == .nothing)
        #expect(store.deleted.isEmpty)
    }

    @Test func anotherStyleReplacesIt() async throws {
        let store = FakeZones()
        store.zones = [zone("a", kind: .auto, center: lausanne)]
        #expect(try await auto(store, style: .positron).run() == .replace)
        #expect(store.deleted == ["a"])
        #expect(store.downloaded.single?.0.styleId == "positron")
    }

    // The player's own zones come first: the automatic one only takes what is left.
    @Test func thePlayersZonesComeFirst() async throws {
        let store = FakeZones()
        store.zones = [zone("mine", kind: .manual, bytes: zonesMaxBytes - 1024)]
        #expect(try await auto(store).run() == .nothing)
        #expect(store.downloaded.isEmpty)
    }
}

/// What leaves the phone (Android: PhotoPrepTest; the pixels are the app's ImageIO, the decisions are here).
struct PhotoPrepTests {
    @Test func aBigPhotoShrinksToTheLongEdgeLimit() {
        #expect(PhotoPrep.plan(width: 4000, height: 3000, rotationDegrees: 0, byteCount: 3_000_000) == .reencode(sampleSize: 2, rotationDegrees: 0, width: 1600, height: 1200))
    }

    // Re-encoding drops EXIF: without baking the rotation in, a portrait photo would
    // reach the placer sideways.
    @Test func theOrientationIsBakedIn() {
        #expect(PhotoPrep.plan(width: 4000, height: 3000, rotationDegrees: 90, byteCount: 3_000_000) == .reencode(sampleSize: 2, rotationDegrees: 90, width: 1200, height: 1600))
        #expect(PhotoPrep.rotationDegrees(exifOrientation: 6) == 90)
        #expect(PhotoPrep.rotationDegrees(exifOrientation: 1) == 0)
        // Even a small one: upright matters more than bytes.
        #expect(PhotoPrep.plan(width: 800, height: 600, rotationDegrees: 270, byteCount: 50_000) == .reencode(sampleSize: 1, rotationDegrees: 270, width: 600, height: 800))
    }

    @Test func aSmallUprightPhotoTravelsAsIs() {
        #expect(PhotoPrep.plan(width: 800, height: 600, rotationDegrees: 0, byteCount: 120_000) == .keep)
        // Small in pixels but heavy in bytes: re-encoded at its size.
        #expect(PhotoPrep.plan(width: 1200, height: 900, rotationDegrees: 0, byteCount: 2_000_000) == .reencode(sampleSize: 1, rotationDegrees: 0, width: 1200, height: 900))
        #expect(!PhotoPrep.keepsReencoded(rotationDegrees: 0, reencodedBytes: 900, originalBytes: 800))
        #expect(PhotoPrep.keepsReencoded(rotationDegrees: 90, reencodedBytes: 900, originalBytes: 800))
    }

    @Test func somethingThatIsNotAnImageIsLeftToTheServer() {
        #expect(PhotoPrep.plan(width: 0, height: 0, rotationDegrees: 0, byteCount: 13) == .keep)
    }
}

/// The stub the app runs against in CI answers the whole game, like the real API where the app looks.
@MainActor
struct StubGameTests {
    private func signedIn(_ stub: StubServer = StubServer(latency: 0)) async throws -> ApiClient {
        let api = ApiClient(baseURL: testBase, cookieJar: SessionCookieJar(store: MemoryCookieStore()), transport: stub)
        try await AuthRepository(api: api, userCache: MemoryUserCache()).signIn(email: StubServer.email, password: StubServer.password)
        return api
    }

    @Test func aFindLandsInTheCollection() async throws {
        let api = try await signedIn()
        let map = MapRepository(api: api)
        let collection = CollectionRepository(api: api, map: map)
        let before = try await collection.load().found.count
        try await HuntRepository(api: api).find(stickerId: SampleStickers.available.id, at: here, photo: photoBytes)
        #expect(try await collection.load().found.count == before + 1)
        let again = await apiError { try await HuntRepository(api: api).find(stickerId: SampleStickers.available.id, at: here, photo: photoBytes) }
        #expect(again?.code == "already_found")
        try await map.refresh()
        #expect(map.stickers?.first { $0.id == SampleStickers.available.id }?.state == .found)
    }

    @Test func aPlacedBirdIsOnTheMapAndInHidden() async throws {
        let api = try await signedIn()
        let map = MapRepository(api: api)
        let place = PlaceRepository(api: api, map: map)
        let draft = PlacementDraft(point: GeoPoint(lng: 6.63, lat: 46.52), device: GeoPoint(lng: 6.63, lat: 46.52), placeName: "Banc", hint: "Dessous", description: "", isPrivate: true)
        let id = try await place.place(draft, photo: photoBytes, clientToken: "tok")
        // A replay of the same gesture plants no second bird.
        #expect(try await place.place(draft, photo: photoBytes, clientToken: "tok") == id)
        #expect(map.stickers?.filter { $0.id == id }.count == 1)
        let hidden = try await CollectionRepository(api: api, map: map).hidden()
        #expect(hidden.first?.id == id)
        #expect(hidden.first?.isPrivate == true)

        try await map.edit(id, body: ["placeName": "Banc du lac"])
        try await map.setArchived(id, true)
        #expect(map.stickers?.first { $0.id == id }?.placeName == "Banc du lac")
        #expect(map.stickers?.first { $0.id == id }?.status == .archived)
        try await map.delete(id)
        #expect(map.stickers?.contains { $0.id == id } == false)
    }

    @Test func theOtherScreensHaveContent() async throws {
        let api = try await signedIn()
        let board = try #require(try await api.get("/api/leaderboard?period=month", as: LeaderboardResponse.self))
        #expect(!board.finders.isEmpty && !board.placers.isEmpty)
        #expect(try await api.get("/api/users/u-alice", as: PublicProfile.self)?.displayName == "alice")
        #expect(try await api.get("/api/profile", as: PublicUser.self)?.email == StubServer.email)
        let finders = try await CollectionRepository(api: api, map: MapRepository(api: api)).finders(SampleStickers.mine.id)
        #expect(!finders.isEmpty)

        let prefs = PrefsRepository(api: api)
        try await prefs.load()
        #expect(prefs.prefs?.termsAcceptedVersion == currentTermsVersion)
        try await prefs.setMapStyle("positron")
        try await prefs.load()
        #expect(prefs.prefs?.mapStyle == "positron")

        #expect(try await api.get("/api/sticker-requests/mine", as: StickerRequest.self) == nil)
        let order = try #require(try await api.post("/api/sticker-requests", CreateStickerRequestBody(deliveryMode: .hand, quantity: 5), as: StickerRequest.self))
        #expect(try await api.get("/api/sticker-requests/mine", as: StickerRequest.self)?.id == order.id)
        #expect(await apiError { _ = try await api.post("/api/sticker-requests", CreateStickerRequestBody(deliveryMode: .hand, quantity: 5), as: StickerRequest.self) }?.code == "already_pending")
        _ = try await api.post("/api/sticker-requests/\(order.id)/cancel", EmptyBody(), as: StickerRequest.self)
        #expect(try await api.get("/api/sticker-requests/history", as: StickerRequestHistoryResponse.self)?.total == 2)
    }

    @Test func aWishAndAReportAreKept() async throws {
        let api = try await signedIn()
        let map = MapRepository(api: api)
        try await map.refresh()
        try await map.setWishlisted(SampleStickers.available.id, true)
        try await map.refresh()
        #expect(map.stickers?.first { $0.id == SampleStickers.available.id }?.wishlisted == true)
        let hunt = HuntRepository(api: api)
        try await hunt.report(stickerId: SampleStickers.available.id, at: here, photo: photoBytes, note: "")
        #expect(await apiError { try await hunt.report(stickerId: SampleStickers.available.id, at: here, photo: photoBytes, note: "") }?.code == "already_reported")
        #expect(await apiError { try await hunt.report(stickerId: SampleStickers.mine.id, at: here, photo: photoBytes, note: "") }?.code == "cannot_report_own")
    }
}
