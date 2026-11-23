import Foundation
import Testing
@testable import OiseauCore

/// Records what it was asked to send; answers with [answer] per record.
@MainActor
final class FakeSender: QueueSender {
    var sent: [String] = []
    let delay: TimeInterval
    let answer: (QueuedAction) -> ApiError?

    init(delay: TimeInterval = 0, _ answer: @escaping (QueuedAction) -> ApiError? = { _ in nil }) {
        self.delay = delay
        self.answer = answer
    }

    func send(_ action: QueuedAction, photo: Data?) async throws(ApiError) {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        sent.append(action.id)
        if let e = answer(action) { throw e }
    }
}

private func obj(_ pairs: (String, JSONValue)...) -> JsonObject {
    Dictionary(uniqueKeysWithValues: pairs)
}

/// The offline queue's drain state machine (Android: OfflineQueueTest; web:
/// offlineQueue.test.ts): what is sent, in which order, and what each answer does to
/// the record.
@MainActor
final class OfflineQueueTests {
    private let dir = tempDir("q")
    private let clock = TestClock(Date(timeIntervalSince1970: 1_790_000_000))
    private var ids = 0

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func queue() -> OfflineQueue {
        OfflineQueue(dir: dir, clock: { [clock] in clock.now }, newId: { [unowned self] in ids += 1; return "id-\(ids)" })
    }

    private func find(_ q: OfflineQueue, user: String = "alice", sticker: String = "s1") -> QueuedAction {
        #expect(q.queueFind(userId: user, stickerId: sticker, placeName: "Banc du lac", at: here, photo: photoBytes))
        clock.advance(1)
        return q.items.last!
    }

    private var filesLeft: [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }

    @Test func aParkedFindSurvivesARestartWithItsPhoto() {
        let q = queue()
        let rec = find(q)
        #expect(rec.kind == .find)
        #expect(rec.capturedAt == 1_790_000_000_000)

        let reopened = queue()
        #expect(reopened.items == [rec])
        #expect(reopened.photo(of: rec) == photoBytes)
    }

    @Test func aDrainSendsOldestFirstAndForgetsWhatLanded() async {
        let q = queue()
        let a = find(q, sticker: "s1")
        let b = find(q, sticker: "s2")
        let sender = FakeSender()

        let r = await q.drain(userId: "alice", sender: sender)

        #expect(sender.sent == [a.id, b.id])
        #expect(r == DrainResult(landed: 2, stillPending: false))
        #expect(q.items.isEmpty)
        // Photos go with their records.
        #expect(filesLeft.isEmpty)
    }

    @Test func alreadyFoundMeansItIsIn() async {
        let q = queue()
        _ = find(q)
        let r = await q.drain(userId: "alice", sender: FakeSender { _ in ApiError(status: 409, code: "already_found") })
        #expect(r.landed == 1)
        #expect(q.items.isEmpty)
    }

    @Test func noNetworkStopsTheDrainAndKeepsEverything() async {
        let q = queue()
        _ = find(q, sticker: "s1")
        _ = find(q, sticker: "s2")
        let sender = FakeSender { _ in ApiError(status: 0, code: ApiError.network, message: "timeout") }

        let r = await q.drain(userId: "alice", sender: sender)

        #expect(sender.sent.count == 1) // stopped at the first one
        #expect(r == DrainResult(landed: 0, stillPending: true))
        #expect(q.items.map(\.attempts) == [1, 0])
        #expect(q.items.allSatisfy { $0.status == .pending })
    }

    @Test func aServerErrorAlsoMeansNotNow() async {
        let q = queue()
        _ = find(q)
        #expect(await q.drain(userId: "alice", sender: FakeSender { _ in ApiError(status: 503, code: "error") }).stillPending)
        #expect(q.items.single?.status == .pending)
    }

    // A replay carries the coordinates of the time: too_far will fail the same forever.
    @Test func aPermanentRefusalMarksThatOneFailedAndGoesOn() async {
        let q = queue()
        let a = find(q, sticker: "gone")
        let b = find(q, sticker: "s2")
        let r = await q.drain(userId: "alice", sender: FakeSender { $0.stickerId == "gone" ? ApiError(status: 422, code: "too_far") : nil })

        #expect(r == DrainResult(landed: 1, stillPending: false, failed: 1))
        let left = q.items.single
        #expect(left?.id == a.id)
        #expect(left?.status == .failed)
        #expect(left?.failCode == "too_far")
        #expect(!q.items.map(\.id).contains(b.id))
        // Failed records are not sent again.
        let again = FakeSender()
        _ = await q.drain(userId: "alice", sender: again)
        #expect(again.sent.isEmpty)
    }

    @Test func anExpiredSessionKeepsEverythingButIsNotANetworkWait() async {
        let q = queue()
        _ = find(q)
        let r = await q.drain(userId: "alice", sender: FakeSender { _ in ApiError(status: 401, code: "unauthorized") })
        #expect(r == DrainResult(landed: 0, stillPending: false))
        #expect(q.items.single?.status == .pending)
    }

    @Test func anotherAccountsRecordsAreNeverSent() async {
        let q = queue()
        let bobs = find(q, user: "bob")
        let sender = FakeSender()
        #expect(await q.drain(userId: "alice", sender: sender).landed == 0)
        #expect(sender.sent.isEmpty)
        #expect(q.items == [bobs])
    }

    // The app (on resume) and the background task (on network) may drain at the same time.
    @Test func concurrentDrainsSendEachActionOnce() async {
        let q = queue()
        _ = find(q, sticker: "s1")
        _ = find(q, sticker: "s2")
        let sender = FakeSender(delay: 0.1)
        let one = Task { await q.drain(userId: "alice", sender: sender) }
        let two = Task { await q.drain(userId: "alice", sender: sender) }
        let results = [await one.value, await two.value]
        #expect(sender.sent.count == 2)
        #expect(results.map(\.landed).reduce(0, +) == 2)
    }

    @Test func aPlacementKeepsWhatTheReplayNeeds() {
        let q = queue()
        let d = PlacementDraft(point: GeoPoint(lng: 6.6330, lat: 46.5200), device: GeoPoint(lng: 6.6323, lat: 46.5197), placeName: " Banc ", hint: "", description: "Vue", isPrivate: true)
        #expect(q.queuePlacement(userId: "alice", draft: d, accuracy: 6, photo: nil))
        let rec = q.items.single!
        #expect(rec.kind == .placement)
        #expect(rec.placeName == "Banc")
        #expect(rec.deviceLng == 6.6323)
        #expect(rec.hint == nil)
        #expect(rec.description == "Vue")
        #expect(rec.isPrivate)
        #expect(q.photo(of: rec) == nil)
    }

    @Test func ignoringAFailedRecordRemovesItAndItsPhoto() {
        let q = queue()
        let rec = find(q)
        #expect(q.photo(of: rec) != nil)
        q.discard(rec.id)
        #expect(q.items.isEmpty)
        #expect(filesLeft.isEmpty)
    }

    @Test func failuresAreExplained() {
        var rec = QueuedAction(id: "i", userId: "u", kind: .find, capturedAt: 0, status: .failed, failCode: "archived")
        #expect(rec.failureReason() == .of("sync_fail_archived"))
        rec.failCode = "whatever"
        #expect(rec.failureReason() == .of("sync_fail_other"))
    }

    // ---- Issue #89: every player action waits here, coalesced; nothing blocks the queue. ----

    // Records written before a field existed still decode (the fields added since have defaults).
    @Test func recordsWithoutTheNewerFieldsStillDecode() throws {
        try Data((#"{"id":"old","userId":"alice","kind":"find","placeName":"Banc","lng":6.6,"lat":46.5,"accuracy":8.0,"# +
            #""capturedAt":1790000000000,"photo":"old.jpg","stickerId":"s1"}"#).utf8).write(to: dir.appendingPathComponent("old.json"))
        let rec = queue().items.single!
        #expect(rec.kind == .find)
        #expect(rec.stickerId == "s1")
        #expect(rec.status == .pending)
        #expect(rec.payload == nil)
    }

    private let on = obj(("on", true))
    private let off = obj(("on", false))

    @Test func aWishlistTappedTwiceOfflineSendsNothing() {
        let q = queue()
        #expect(q.queueChange(userId: "alice", kind: .wishlist, stickerId: "s1", payload: on))
        #expect(q.queueChange(userId: "alice", kind: .wishlist, stickerId: "s1", payload: off))
        #expect(q.items.isEmpty)
    }

    @Test func flagsCoalesceKeyByKey() {
        let q = queue()
        q.queueChange(userId: "alice", kind: .stickerToggle, stickerId: "s1", payload: obj(("isPrivate", true)))
        q.queueChange(userId: "alice", kind: .stickerToggle, stickerId: "s1", payload: obj(("status", "archived")))
        q.queueChange(userId: "alice", kind: .stickerToggle, stickerId: "s1", payload: obj(("isPrivate", false))) // back to the server's
        #expect(q.items.single?.payload == obj(("status", "archived")))
    }

    @Test func prefsMergeIntoOneRecordLaterWins() {
        let q = queue()
        q.queueChange(userId: "alice", kind: .prefs, stickerId: nil, payload: obj(("mapStyle", "liberty"), ("hideMapSpoilers", true)))
        q.queueChange(userId: "alice", kind: .prefs, stickerId: nil, payload: obj(("mapStyle", "positron"), ("placementCharterAccepted", true)))
        #expect(q.items.single?.payload == obj(("mapStyle", "positron"), ("hideMapSpoilers", true), ("placementCharterAccepted", true)))
    }

    @Test func deletingABirdDropsItsOtherParkedChangesButNotAReport() {
        let q = queue()
        q.queueChange(userId: "alice", kind: .stickerToggle, stickerId: "s1", payload: obj(("isPrivate", true)))
        q.queueChange(userId: "alice", kind: .stickerEdit, stickerId: "s1", payload: obj(("hint", "Sous le banc")))
        q.queueChange(userId: "alice", kind: .wishlist, stickerId: "s2", payload: on)
        q.queueReport(userId: "alice", stickerId: "s1", placeName: "Banc", at: here, photo: photoBytes, note: "")
        q.queueChange(userId: "alice", kind: .stickerDelete, stickerId: "s1", payload: [:])
        #expect(q.items.map { "\($0.kind.rawValue) \($0.stickerId!)" } == ["wishlist s2", "report s1", "sticker-delete s1"])
    }

    @Test func editsAreKeptOneByOneWithTheirTime() {
        let q = queue()
        q.queueChange(userId: "alice", kind: .stickerEdit, stickerId: "s1", payload: obj(("hint", "a")))
        clock.advance(60)
        q.queueChange(userId: "alice", kind: .stickerEdit, stickerId: "s1", payload: obj(("hint", "b")))
        #expect(q.items.map(\.capturedAt) == [1_790_000_000_000, 1_790_000_060_000])
    }

    // Before #89 an unknown 4xx was treated as "not now": one bad record held every
    // other one back for good.
    @Test func anyRefusalFailsThatRecordAndNeverBlocksTheRest() async {
        let q = queue()
        q.queueChange(userId: "alice", kind: .stickerEdit, stickerId: "s1", payload: obj(("hint", "x")))
        clock.advance(0.001)
        _ = find(q, sticker: "s2")
        let r = await q.drain(userId: "alice", sender: FakeSender { $0.stickerId == "s1" ? ApiError(status: 403, code: "forbidden") : nil })
        #expect(r == DrainResult(landed: 1, stillPending: false, failed: 1))
        #expect(q.items.single?.failCode == "forbidden")
    }

    @Test func aPlainServerErrorIsRetriedThenGivenUp() async {
        let q = queue()
        _ = find(q)
        let boom = FakeSender { _ in ApiError(status: 500, code: "error") }
        for _ in 0..<(OfflineQueue.maxServerErrors - 1) { #expect(await q.drain(userId: "alice", sender: boom).stillPending) }
        let last = await q.drain(userId: "alice", sender: boom)
        #expect(last.failed == 1)
        #expect(q.items.single?.failCode == OfflineQueue.serverError)
        #expect(q.items.single?.failureReason() == .of("sync_fail_server"))
    }

    @Test func aChangeToABirdThatIsGoneIsDropped() async {
        let q = queue()
        q.queueChange(userId: "alice", kind: .wishlist, stickerId: "gone", payload: on)
        let r = await q.drain(userId: "alice", sender: FakeSender { _ in ApiError(status: 404, code: "not_found") })
        #expect(r.failed == 1)
        #expect(q.items.isEmpty)
    }

    @Test func aParkedReportKeepsItsNoteAndPhoto() async {
        let q = queue()
        #expect(q.queueReport(userId: "alice", stickerId: "s1", placeName: "Banc", at: here, photo: photoBytes, note: "  Plus là  "))
        let rec = q.items.single!
        #expect(rec.kind == .report)
        #expect(rec.payload == obj(("note", "Plus là")))
        #expect(q.photo(of: rec) != nil)
        // Already reported, by this phone or another: done.
        #expect(await q.drain(userId: "alice", sender: FakeSender { _ in ApiError(status: 409, code: "already_reported") }).landed == 1)
    }

    @Test func whatIsParkedPerBird() {
        let q = queue()
        q.queueChange(userId: "alice", kind: .wishlist, stickerId: "s1", payload: on)
        #expect(q.hasPending(userId: "alice", stickerId: "s1"))
        #expect(!q.hasPending(userId: "alice", stickerId: "s2"))
        #expect(!q.hasPending(userId: "bob", stickerId: "s1"))
        #expect(!q.hasPending(userId: "alice", stickerId: nil, kind: .prefs))
    }

    @Test func forgettingAnAccountKeepsTheOthers() {
        let q = queue()
        _ = find(q, user: "u1")
        _ = find(q, user: "u2")
        q.clearFor("u1")
        #expect(q.items.map(\.userId) == ["u2"])
    }
}

extension Array {
    /// The one element, or nil when there are none or several (Kotlin's singleOrNull).
    var single: Element? { count == 1 ? first : nil }
}

/// What each parked kind sends when it is replayed — the same calls as live (Android: QueueSenderTest).
@MainActor
struct QueueSenderTests {
    private func rec(_ kind: QueuedKind, _ payload: JsonObject? = nil) -> QueuedAction {
        QueuedAction(id: "r", userId: "alice", kind: kind, capturedAt: 1_790_000_000_000, stickerId: "s1", payload: payload)
    }

    private func sender(_ server: ScriptedTransport) -> ApiQueueSender {
        let api = client(server)
        return ApiQueueSender(api: api, hunt: HuntRepository(api: api), place: PlaceRepository(api: api, map: MapRepository(api: api)))
    }

    @Test func eachKindReplaysItsCall() async throws {
        let server = ScriptedTransport()
        for _ in 0..<6 { await server.json(200, "{}") }
        let s = sender(server)
        try await s.send(rec(.wishlist, ["on": true]), photo: nil)
        try await s.send(rec(.wishlist, ["on": false]), photo: nil)
        try await s.send(rec(.stickerToggle, ["isPrivate": true]), photo: nil)
        try await s.send(rec(.stickerDelete, [:]), photo: nil)
        try await s.send(rec(.prefs, ["placementCharterAccepted": true]), photo: nil)
        try await s.send(rec(.stickerEdit, ["hint": .null]), photo: nil)

        #expect(sent(await server.takeRequest()) == #"POST /api/wishlist {"stickerId":"s1"}"#)
        #expect(sent(await server.takeRequest()) == "DELETE /api/wishlist/s1")
        #expect(sent(await server.takeRequest()) == #"PATCH /api/stickers/s1 {"isPrivate":true}"#)
        #expect(sent(await server.takeRequest()) == "DELETE /api/stickers/s1")
        #expect(sent(await server.takeRequest()) == #"PATCH /api/me/prefs {"placementCharterAccepted":true}"#)
        // The edit carries when it was made: the server checks the 5-minute window against it.
        #expect(sent(await server.takeRequest()) == #"PATCH /api/stickers/s1 {"capturedAt":1790000000000,"hint":null}"#)
    }

    @Test func aReportReplaysItsMultipart() async throws {
        let server = ScriptedTransport()
        await server.json(201, #"{"id":"rep1"}"#)
        var r = rec(.report, ["note": "Plus là"])
        r.lng = 6.6
        r.lat = 46.5
        try await sender(server).send(r, photo: photoBytes)
        let req = await server.takeRequest()
        #expect(req.url.path == "/api/reports")
        #expect(parts(req) == ["stickerId": "s1", "lng": "6.6", "lat": "46.5", "note": "Plus là", "photo": "report.jpg"])
    }

    @Test func aFindWithoutItsPhotoIsRefusedWithoutAsking() async {
        let server = ScriptedTransport()
        let e = await apiError { try await sender(server).send(rec(.find), photo: nil) }
        #expect(e?.code == "photo_required")
        #expect(await server.requestCount == 0)
    }
}

/// A refetch while changes are parked must not undo them on screen (Android: PendingOverlayTest).
struct PendingOverlayTests {
    private let mine = SampleStickers.mine
    private let other = SampleStickers.available

    private func rec(_ kind: QueuedKind, _ sticker: String, _ payload: JsonObject, user: String = "alice", status: QueuedStatus = .pending, at: Int64 = 1) -> QueuedAction {
        QueuedAction(id: "\(kind)-\(sticker)-\(at)", userId: user, kind: kind, capturedAt: at, status: status, stickerId: sticker, payload: payload)
    }

    @Test func parkedChangesAreLaidOnTheServersList() {
        let list = [mine, other].withPending([
            rec(.wishlist, other.id, ["on": .bool(!other.wishlisted)]),
            rec(.stickerToggle, mine.id, ["isPrivate": true, "status": "archived"]),
            rec(.stickerEdit, mine.id, ["placeName": "Nouveau", "hint": .null], at: 2),
        ], userId: "alice")
        let m = list.first { $0.id == mine.id }!
        #expect(m.isPrivate)
        #expect(m.status == .archived)
        #expect(m.placeName == "Nouveau")
        #expect(m.hint == nil) // a JSON null clears it
        #expect(list.first { $0.id == other.id }!.wishlisted == !other.wishlisted)
    }

    @Test func aParkedDeletionKeepsTheBirdOff() {
        let list = [mine, other].withPending([rec(.stickerDelete, mine.id, [:])], userId: "alice")
        #expect(list.map(\.id) == [other.id])
    }

    // The Collection's « Cachés », from the cache or the server, shows them as made too.
    @Test func myPlacedBirdsGetTheSameTreatment() {
        let placed = MyPlacedSticker(
            id: "p1", lng: 6.6, lat: 46.5, placeName: "Banc", hint: "Dessous", placedAt: "2026-11-19T10:00:00Z", countryCode: "CH",
            status: .active, isPrivate: false, findCount: 0, reportCount: 0, hasOpenReport: false
        )
        var gone = placed
        gone.id = "p2"
        let out = [placed, gone].withPendingPlaced([
            rec(.stickerToggle, "p1", ["isPrivate": true, "status": "archived"]),
            rec(.stickerEdit, "p1", ["hint": .null], at: 2),
            rec(.stickerDelete, "p2", [:]),
        ], userId: "alice")
        #expect(out.count == 1)
        #expect(out.first?.isPrivate == true)
        #expect(out.first?.status == .archived)
        #expect(out.first?.hint == nil)
    }

    @Test func onlyThisAccountsPendingRecordsCount() {
        let list = [other]
        let flip: JsonObject = ["on": .bool(!other.wishlisted)]
        #expect(list.withPending([rec(.wishlist, other.id, flip, user: "bob")], userId: "alice") == list)
        #expect(list.withPending([rec(.wishlist, other.id, flip, status: .failed)], userId: "alice") == list)
        #expect(list.withPending([rec(.wishlist, other.id, flip)], userId: nil) == list)
    }

    @Test func aPatchMovesAndRenamesAPin() {
        let p = other.applyPatch(["lng": 6.7, "lat": 46.6, "placeName": "Ailleurs", "description": "Là"])
        #expect(p.point == GeoPoint(lng: 6.7, lat: 46.6))
        #expect(p.placeName == "Ailleurs")
        #expect(p.description == "Là")
        #expect(p.hint == other.hint) // absent: kept
    }
}

/// A change is sent now, or parked when nobody answers — never lost, never reordered (Android: OutboxTest).
@MainActor
final class OutboxTests {
    private let dir = tempDir("outbox")
    private var offline = false
    private var drains = 0
    private lazy var queue = OfflineQueue(dir: dir)
    private lazy var outbox = Outbox(queue: queue, userId: { "alice" }, knownOffline: { [unowned self] in offline }, schedule: {}, drainNow: { [unowned self] in drains += 1 })
    private let on: JsonObject = ["on": true]

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func answeredIsSentNow() async throws {
        var calls = 0
        #expect(try await outbox.change(.wishlist, stickerId: "s1", payload: on) { () async throws(ApiError) in calls += 1 } == .now)
        #expect(calls == 1)
        #expect(queue.items.isEmpty)
    }

    @Test func knownOfflineIsParkedWithoutTrying() async throws {
        offline = true
        let sent = try await outbox.change(.wishlist, stickerId: "s1", payload: on) { () async throws(ApiError) in Issue.record("no request without a network") }
        #expect(sent == .later(.noNetwork))
        #expect(queue.items.single?.kind == .wishlist)
    }

    @Test func aServerDownIsParkedAndSaidAsSuch() async throws {
        let sent = try await outbox.change(.wishlist, stickerId: "s1", payload: on) { () async throws(ApiError) in throw ApiError(status: 502, code: "error") }
        #expect(sent == .later(.serverDown))
        #expect(queue.items.count == 1)
    }

    @Test func aRefusalIsThrownAndNothingIsParked() async {
        let e = await apiError {
            _ = try await self.outbox.change(.stickerEdit, stickerId: "s1", payload: self.on) { () async throws(ApiError) in throw ApiError(status: 403, code: "edit_window_closed") }
        }
        #expect(e?.code == "edit_window_closed")
        #expect(queue.items.isEmpty)
    }

    // An offline ❤ then an online un-❤: sent live, the un-❤ would land first and the
    // replayed ❤ last — the opposite of what the player did.
    @Test func aChangeToABirdWithSomethingParkedGoesBehindIt() async throws {
        offline = true
        _ = try await outbox.change(.stickerToggle, stickerId: "s1", payload: ["isPrivate": true]) { () async throws(ApiError) in }
        offline = false
        var live = 0
        _ = try await outbox.change(.stickerToggle, stickerId: "s1", payload: ["status": "archived"]) { () async throws(ApiError) in live += 1 }
        #expect(live == 0)
        #expect(drains == 1)
        #expect(queue.items.count == 1) // coalesced into the parked one
    }

    @Test func signedOutIsSentStraightAway() async throws {
        let anonymous = Outbox(queue: queue, userId: { nil }, knownOffline: { true }, schedule: {}, drainNow: {})
        var calls = 0
        #expect(try await anonymous.change(.prefs, stickerId: nil, payload: [:]) { () async throws(ApiError) in calls += 1 } == .now)
        #expect(calls == 1)
    }
}
