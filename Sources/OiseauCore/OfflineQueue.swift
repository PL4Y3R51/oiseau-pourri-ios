import Foundation

// Actions taken without a server, replayed once there is one (Android:
// data/OfflineQueue.kt; web: offlineQueue.ts). The game is played in forests, on
// mountains, abroad with roaming off — and the server can be down too (issue #89):
// neither must mean a wasted walk or a lost tap. Finds and placements are physical
// and one-shot (you have to be standing there); every other player action waits
// here too: reports, the wishlist, the private and archived flags, edits,
// deletions, prefs.
//
// One JSON file per action plus its photo, in a directory the app keeps out of
// backups: a handful of records don't justify a database, and they must never be
// restored onto another phone.

public enum QueuedKind: String, Codable, Sendable, CaseIterable {
    case find
    case placement
    case report
    /// [QueuedAction.payload] `{"on": true|false}`.
    case wishlist
    /// Own bird's private / archived flags: a PATCH body of `isPrivate` and/or `status`; coalesced.
    case stickerToggle = "sticker-toggle"
    /// Own bird's texts or position: a PATCH body, sent with its capture time (the 5-minute window).
    case stickerEdit = "sticker-edit"
    case stickerDelete = "sticker-delete"
    /// The account's synced prefs: one merged PATCH body per account.
    case prefs
}

public enum QueuedStatus: String, Codable, Sendable {
    case pending
    /// The server said "never"; kept until the player dismisses it.
    case failed
}

/// One parked action.
public struct QueuedAction: Codable, Hashable, Sendable {
    /// Also the idempotency token of a placement (`clientToken`).
    public var id: String
    /// Whose queue this is: a record is never sent for another account.
    public var userId: String
    public var kind: QueuedKind
    /// Shown in the pending list; a placement's may be blank (the server geocodes it).
    public var placeName: String = ""
    public var lng: Double = 0
    public var lat: Double = 0
    public var accuracy: Double = 0
    /// Epoch ms of the gesture; the server trusts it within FIND_TRUST_WINDOW_MS.
    public var capturedAt: Int64
    public var status: QueuedStatus = .pending
    /// The server's code once it is known the action can never succeed.
    public var failCode: String?
    public var attempts: Int = 0
    /// File name next to the record; required for a find and a report, optional for a placement.
    public var photo: String?
    /// The bird it is about (find, report and every sticker kind).
    public var stickerId: String?
    // Placement
    public var deviceLng: Double?
    public var deviceLat: Double?
    public var hint: String?
    public var description: String?
    public var isPrivate: Bool = false
    /// The body of the kinds that are a plain JSON call (see [QueuedKind]); a report's `note`.
    public var payload: JsonObject?

    public init(
        id: String, userId: String, kind: QueuedKind, placeName: String = "", lng: Double = 0, lat: Double = 0,
        accuracy: Double = 0, capturedAt: Int64, status: QueuedStatus = .pending, failCode: String? = nil,
        attempts: Int = 0, photo: String? = nil, stickerId: String? = nil, deviceLng: Double? = nil,
        deviceLat: Double? = nil, hint: String? = nil, description: String? = nil, isPrivate: Bool = false,
        payload: JsonObject? = nil
    ) {
        self.id = id
        self.userId = userId
        self.kind = kind
        self.placeName = placeName
        self.lng = lng
        self.lat = lat
        self.accuracy = accuracy
        self.capturedAt = capturedAt
        self.status = status
        self.failCode = failCode
        self.attempts = attempts
        self.photo = photo
        self.stickerId = stickerId
        self.deviceLng = deviceLng
        self.deviceLat = deviceLat
        self.hint = hint
        self.description = description
        self.isPrivate = isPrivate
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decode(String.self, forKey: .userId)
        kind = try c.decode(QueuedKind.self, forKey: .kind)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName) ?? ""
        lng = try c.decodeIfPresent(Double.self, forKey: .lng) ?? 0
        lat = try c.decodeIfPresent(Double.self, forKey: .lat) ?? 0
        accuracy = try c.decodeIfPresent(Double.self, forKey: .accuracy) ?? 0
        capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        status = try c.decodeIfPresent(QueuedStatus.self, forKey: .status) ?? .pending
        failCode = try c.decodeIfPresent(String.self, forKey: .failCode)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        photo = try c.decodeIfPresent(String.self, forKey: .photo)
        stickerId = try c.decodeIfPresent(String.self, forKey: .stickerId)
        deviceLng = try c.decodeIfPresent(Double.self, forKey: .deviceLng)
        deviceLat = try c.decodeIfPresent(Double.self, forKey: .deviceLat)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        payload = try c.decodeIfPresent(JsonObject.self, forKey: .payload)
    }

    /// A wishlist record's state.
    public var wishlistOn: Bool? { payload?["on"]?.boolValue }

    /// Why a parked action can never be sent (web: failureReason).
    public func failureReason() -> UiText {
        switch failCode {
        case "archived": return .of("sync_fail_archived")
        case "not_found": return .of("sync_fail_not_found")
        case "too_far": return .of("sync_fail_too_far")
        case "too_far_from_device": return .of("sync_fail_too_far_from_device")
        case "photo_required": return .of("sync_fail_photo")
        case "edit_window_closed": return .of("sync_fail_edit_window")
        case "reposition_locked": return .of("sync_fail_reposition_locked")
        case "cannot_report_own": return .of("report_error_own")
        case OfflineQueue.serverError: return .of("sync_fail_server")
        default: return .of("sync_fail_other")
        }
    }
}

/// Sends one parked action; throws [ApiError] like the live calls.
@MainActor
public protocol QueueSender: AnyObject {
    func send(_ action: QueuedAction, photo: Data?) async throws(ApiError)
}

/// What a drain did: how many landed, how many the server refused for good, and
/// whether something still waits for the network or the server.
public struct DrainResult: Equatable, Sendable {
    public var landed: Int
    public var stillPending: Bool
    public var failed: Int

    public init(landed: Int, stillPending: Bool, failed: Int = 0) {
        self.landed = landed
        self.stillPending = stillPending
        self.failed = failed
    }
}

@MainActor
public final class OfflineQueue {
    /// A plain 500 this many times on the same record: it won't get better by itself.
    public static let maxServerErrors = 5
    public static let serverError = "server_error"
    /// The kinds about an existing bird: a 404 means the bird is gone.
    public static let birdChanges: Set<QueuedKind> = [.wishlist, .stickerToggle, .stickerEdit, .stickerDelete]

    private let dir: URL
    private let clock: () -> Date
    private let newId: () -> String
    private let drainLock = AsyncMutex()

    /// Every account's records, oldest first. Filter by user for display.
    public private(set) var items: [QueuedAction] = [] {
        didSet { if items != oldValue { onChange?(items) } }
    }

    public var onChange: (([QueuedAction]) -> Void)?

    public init(dir: URL, clock: @escaping () -> Date = Date.init, newId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.dir = dir
        self.clock = clock
        self.newId = newId
        items = readAll()
    }

    private var now: Int64 { epochMs(clock()) }

    /// Park a find. False when storage refused it, so the caller reports a plain failure.
    @discardableResult
    public func queueFind(userId: String, stickerId: String, placeName: String, at: Position, photo: Data) -> Bool {
        enqueue(
            QueuedAction(
                id: newId(), userId: userId, kind: .find, placeName: placeName,
                lng: at.point.lng, lat: at.point.lat, accuracy: at.accuracyM, capturedAt: now, stickerId: stickerId
            ),
            photo: photo
        )
    }

    /// Same, for a bird placed with no connection. [id] is the clientToken the live
    /// try already sent, if there was one: its answer may only have been lost.
    @discardableResult
    public func queuePlacement(userId: String, draft d: PlacementDraft, accuracy: Double, photo: Data?, id: String? = nil) -> Bool {
        enqueue(
            QueuedAction(
                id: id ?? newId(), userId: userId, kind: .placement, placeName: d.placeName.trimmingCharacters(in: .whitespacesAndNewlines),
                lng: d.point.lng, lat: d.point.lat, accuracy: accuracy, capturedAt: now,
                deviceLng: d.device.lng, deviceLat: d.device.lat,
                hint: d.hint.isBlank ? nil : d.hint, description: d.description.isBlank ? nil : d.description,
                isPrivate: d.isPrivate
            ),
            photo: photo
        )
    }

    /// A missing-bird report: like a find, it needs the place and the photo of the moment.
    @discardableResult
    public func queueReport(userId: String, stickerId: String, placeName: String, at: Position, photo: Data, note: String) -> Bool {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return enqueue(
            QueuedAction(
                id: newId(), userId: userId, kind: .report, placeName: placeName,
                lng: at.point.lng, lat: at.point.lat, accuracy: at.accuracyM, capturedAt: now,
                stickerId: stickerId, payload: note.isEmpty ? nil : ["note": .string(note)]
            ),
            photo: photo
        )
    }

    /// Park a change that is a plain JSON call ([QueuedKind.wishlist], the sticker
    /// kinds, [QueuedKind.prefs]), coalesced with what is already parked so the
    /// replay sends the player's intent, not every tap:
    /// - a wishlist or a flag flipped back to where the server has it cancels out;
    /// - prefs merge into one record per account (later values win);
    /// - a deletion makes the bird's other parked changes moot.
    /// False when storage refused it.
    @discardableResult
    public func queueChange(userId: String, kind: QueuedKind, stickerId: String?, payload: JsonObject, placeName: String = "") -> Bool {
        defer { refresh() }
        let mine = readAll().filter { $0.userId == userId && $0.status == .pending && $0.stickerId == stickerId }
        let next = QueuedAction(id: newId(), userId: userId, kind: kind, placeName: placeName, capturedAt: now, stickerId: stickerId, payload: payload)
        switch kind {
        case .wishlist, .stickerToggle:
            guard var prev = mine.first(where: { $0.kind == kind }) else { return write(next) }
            // Keys set again to the other value were flipped back: the server still has them.
            var merged = prev.payload ?? [:]
            for (k, v) in payload {
                if let old = merged[k], old != v { merged[k] = nil } else { merged[k] = v }
            }
            if merged.isEmpty { delete(prev.id); return true }
            prev.payload = merged
            return write(prev)
        case .prefs:
            guard var prev = mine.first(where: { $0.kind == .prefs }) else { return write(next) }
            prev.payload = (prev.payload ?? [:]).merging(payload) { _, new in new }
            return write(prev)
        case .stickerDelete:
            // The bird goes: its wishlist, flags and edits with it.
            for rec in mine where rec.kind != .report { delete(rec.id) }
            return write(next)
        default:
            return write(next)
        }
    }

    /// Whether this account has something parked about this bird (or, for nil, its
    /// prefs): a new change goes behind it.
    public func hasPending(userId: String, stickerId: String?, kind: QueuedKind? = nil) -> Bool {
        items.contains { $0.userId == userId && $0.status == .pending && $0.stickerId == stickerId && (kind == nil || $0.kind == kind) }
    }

    /// The photo kept with [a], if any.
    public func photo(of a: QueuedAction) -> Data? {
        guard let name = a.photo else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    /// The « Ignorer » action on a failed record.
    public func discard(_ id: String) {
        delete(id)
        refresh()
    }

    /// Forget an account's queue (the account itself is gone).
    public func clearFor(_ userId: String) {
        for rec in items where rec.userId == userId { delete(rec.id) }
        refresh()
    }

    /// Send this account's pending actions, oldest first (web: drainQueue). No usable
    /// answer (no network, a 5xx, a timeout) or an expired session stops the drain —
    /// "not now", not "never" — and the records stay; a refusal marks that one record
    /// failed and goes on, so one bad record never blocks the rest. Concurrent calls
    /// never send twice: the second waits, then finds nothing left.
    public func drain(userId: String, sender: any QueueSender) async -> DrainResult {
        await drainLock.withLock { () async -> DrainResult in
            var landed = 0
            var failed = 0
            var blocked = false
            let mine = items.filter { $0.userId == userId && $0.status == .pending }.sorted(by: Self.order)
            for rec in mine {
                do throws(ApiError) {
                    // A placement replay that already landed answers 200 with the bird it made.
                    try await sender.send(rec, photo: photo(of: rec))
                    delete(rec.id)
                    landed += 1
                } catch {
                    if error.code == "already_found" || error.code == "already_reported" {
                        // Already done, however it got there (a double drain, another device).
                        delete(rec.id)
                        landed += 1
                    } else if Self.birdChanges.contains(rec.kind) && error.status == 404 {
                        // A change to a bird that is gone: nothing left to change.
                        delete(rec.id)
                        failed += 1
                    } else if error.isUnauthorized {
                        // Session expired: keep everything for after the next sign-in (which
                        // drains again). Not "pending" for the network: retrying won't help.
                        break
                    } else if error.isUnavailable {
                        var next = rec
                        next.attempts += 1
                        // A plain 500 may be this record's own fault: give up on it eventually.
                        if error.status == 500 && next.attempts >= Self.maxServerErrors {
                            next.status = .failed
                            next.failCode = Self.serverError
                            write(next)
                            failed += 1
                            continue
                        }
                        // Still offline, or the server is having a bad time.
                        write(next)
                        blocked = true
                        break
                    } else {
                        // A refusal: never, whatever the code.
                        var next = rec
                        next.status = .failed
                        next.failCode = error.code
                        next.attempts += 1
                        write(next)
                        failed += 1
                    }
                }
            }
            refresh()
            return DrainResult(landed: landed, stillPending: blocked, failed: failed)
        }
    }

    // MARK: - Files

    private func enqueue(_ rec: QueuedAction, photo: Data?) -> Bool {
        defer { refresh() }
        var rec = rec
        if let photo {
            let name = "\(rec.id).jpg"
            guard writeAtomically(photo, to: dir.appendingPathComponent(name)) else { return false }
            rec.photo = name
        }
        return write(rec)
    }

    @discardableResult
    private func write(_ rec: QueuedAction) -> Bool {
        guard let data = try? ApiJson.encoder.encode(rec) else { return false }
        return writeAtomically(data, to: dir.appendingPathComponent("\(rec.id).json"))
    }

    private func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).jpg"))
    }

    /// Oldest first; the id breaks ties so the order is the same on every read.
    private static func order(_ a: QueuedAction, _ b: QueuedAction) -> Bool {
        a.capturedAt != b.capturedAt ? a.capturedAt < b.capturedAt : a.id < b.id
    }

    private func readAll() -> [QueuedAction] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? ApiJson.decoder.decode(QueuedAction.self, from: $0) } }
            .sorted(by: Self.order)
    }

    private func refresh() {
        items = readAll()
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The live API calls, for a replay: same endpoints, plus the capture time and the
/// placement's token (Android: ApiQueueSender).
@MainActor
public final class ApiQueueSender: QueueSender {
    private let api: ApiClient
    private let hunt: HuntRepository
    private let place: PlaceRepository

    public init(api: ApiClient, hunt: HuntRepository, place: PlaceRepository) {
        self.api = api
        self.hunt = hunt
        self.place = place
    }

    public func send(_ action: QueuedAction, photo: Data?) async throws(ApiError) {
        let at = Position(GeoPoint(lng: action.lng, lat: action.lat), accuracyM: action.accuracy, at: dateOf(epochMs: action.capturedAt))
        func sticker() throws(ApiError) -> String {
            guard let id = action.stickerId else { throw ApiError(status: 400, code: "invalid_input") }
            return id
        }
        func requiredPhoto() throws(ApiError) -> Data {
            guard let photo else { throw ApiError(status: 400, code: "photo_required") }
            return photo
        }
        switch action.kind {
        case .find:
            _ = try await hunt.find(stickerId: sticker(), at: at, photo: requiredPhoto(), capturedAt: action.capturedAt)
        case .placement:
            let draft = PlacementDraft(
                point: at.point,
                device: GeoPoint(lng: action.deviceLng ?? action.lng, lat: action.deviceLat ?? action.lat),
                placeName: action.placeName,
                hint: action.hint ?? "",
                description: action.description ?? "",
                isPrivate: action.isPrivate
            )
            _ = try await place.place(draft, photo: photo, clientToken: action.id, capturedAt: action.capturedAt)
        case .report:
            _ = try await hunt.report(stickerId: sticker(), at: at, photo: requiredPhoto(), note: action.payload?["note"]?.stringValue ?? "")
        case .wishlist:
            if action.payload?["on"]?.boolValue == true {
                _ = try await api.post("/api/wishlist", AddWishlistBody(stickerId: sticker()), as: Ignored.self)
            } else {
                _ = try await api.delete("/api/wishlist/\(sticker())", as: Ignored.self)
            }
        case .stickerToggle:
            try await api.patch("/api/stickers/\(sticker())", json: action.payload ?? [:])
        case .stickerEdit:
            // When it was made: the server checks the 5-minute text window against it.
            var body = action.payload ?? [:]
            body["capturedAt"] = .int(action.capturedAt)
            try await api.patch("/api/stickers/\(sticker())", json: body)
        case .stickerDelete:
            _ = try await api.delete("/api/stickers/\(sticker())", as: Ignored.self)
        case .prefs:
            try await api.patch("/api/me/prefs", json: action.payload ?? [:])
        }
    }
}
