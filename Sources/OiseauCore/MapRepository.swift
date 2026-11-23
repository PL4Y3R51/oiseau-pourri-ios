import Foundation

/// The birds on the map (`GET /api/map`; Android: data/MapRepository.kt). Kept in
/// memory so the map paints at once, fetched again once a minute old, and kept on
/// disk so a cold start without a network (or with the API down) still shows the
/// last pins.
///
/// Every change is shown at once and goes through the [Outbox] (issue #89): sent
/// now, or parked until the server answers — a refusal reverts it and throws.
/// Lifecycle changes (archive, delete, edit) refetch once the server has them,
/// since they can touch more than the one bird's pin.
@MainActor
public final class MapRepository {
    private let api: ApiClient
    /// The last list fetched, per account; deleted on sign-out ([clear]).
    private let snapshot: URL?
    /// Nil in tests that only read: every change is then sent straight away.
    private let outbox: Outbox?
    /// This account's parked changes, laid on every list fetched ([withPending]).
    private let pending: () -> [QueuedAction]
    private let userId: () -> String?
    private let clock: () -> Date

    /// nil until the first load.
    public private(set) var stickers: [MapSticker]? {
        didSet { onChange?(stickers) }
    }

    public var onChange: (([MapSticker]?) -> Void)?

    private var fetchedAt: Date = .distantPast

    public static let staleAfter: TimeInterval = 60

    public init(
        api: ApiClient,
        snapshot: URL? = nil,
        outbox: Outbox? = nil,
        pending: @escaping () -> [QueuedAction] = { [] },
        userId: @escaping () -> String? = { nil },
        clock: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.snapshot = snapshot
        self.outbox = outbox
        self.pending = pending
        self.userId = userId
        self.clock = clock
    }

    public func isStale(maxAge: TimeInterval = MapRepository.staleAfter) -> Bool {
        stickers == nil || clock().timeIntervalSince(fetchedAt) > maxAge
    }

    public func refresh() async throws(ApiError) {
        let list: [MapSticker]
        do {
            list = try await api.get("/api/map", as: [MapSticker].self) ?? []
        } catch {
            // No network or no server on a cold start: the last known map, while the error still shows.
            if error.isUnavailable && stickers == nil { restore() }
            throw error
        }
        stickers = list.withPending(pending(), userId: userId())
        fetchedAt = clock()
        save(list)
    }

    public func refreshIfStale() async throws(ApiError) {
        if isStale() { try await refresh() }
    }

    public func clear() {
        stickers = nil
        fetchedAt = .distantPast
        if let snapshot { try? FileManager.default.removeItem(at: snapshot) }
    }

    private func save(_ list: [MapSticker]) {
        guard let snapshot, let data = try? ApiJson.encoder.encode(list) else { return }
        _ = writeAtomically(data, to: snapshot)
    }

    private func restore() {
        guard let snapshot, let data = try? Data(contentsOf: snapshot),
              let list = try? ApiJson.decoder.decode([MapSticker].self, from: data) else { return }
        // fetchedAt stays in the past: stale, so the next chance at a network refetches it.
        if stickers == nil { stickers = list.withPending(pending(), userId: userId()) }
    }

    // MARK: - Changes

    private func patch(_ id: String, _ change: (inout MapSticker) -> Void) {
        guard var list = stickers, let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        stickers = list
    }

    private func placeNameOf(_ id: String) -> String { stickers?.first { $0.id == id }?.placeName ?? "" }

    /// Now, or parked by the [Outbox]; a refusal throws after [revert].
    private func send(_ kind: QueuedKind, _ id: String, _ payload: JsonObject, revert: () async -> Void, call: () async throws(ApiError) -> Void) async throws(ApiError) -> Sent {
        do {
            if let outbox {
                return try await outbox.change(kind, stickerId: id, payload: payload, placeName: placeNameOf(id), send: call)
            }
            try await call()
            return .now
        } catch {
            await revert()
            throw error
        }
    }

    /// Optimistic, reverted if the server refuses (web: StickerSheet#toggleWishlist).
    @discardableResult
    public func setWishlisted(_ id: String, _ on: Bool) async throws(ApiError) -> Sent {
        patch(id) { $0.wishlisted = on }
        return try await send(.wishlist, id, ["on": .bool(on)], revert: { patch(id) { $0.wishlisted = !on } }) { () async throws(ApiError) in
            if on {
                _ = try await api.post("/api/wishlist", AddWishlistBody(stickerId: id), as: Ignored.self)
            } else {
                _ = try await api.delete("/api/wishlist/\(id)", as: Ignored.self)
            }
        }
    }

    /// Optimistic, like the wishlist. Owner only (server-enforced). The PATCH names
    /// only this field: a text key alongside would count as an edit, refused after 5 minutes.
    @discardableResult
    public func setPrivate(_ id: String, _ on: Bool) async throws(ApiError) -> Sent {
        patch(id) { $0.isPrivate = on }
        return try await send(.stickerToggle, id, ["isPrivate": .bool(on)], revert: { patch(id) { $0.isPrivate = !on } }) { () async throws(ApiError) in
            _ = try await api.patch("/api/stickers/\(id)", UpdateStickerBody(isPrivate: on), as: Ignored.self)
        }
    }

    /// Archive (also settles open reports server-side) or reactivate; refetched once the server has it.
    @discardableResult
    public func setArchived(_ id: String, _ archived: Bool) async throws(ApiError) -> Sent {
        let status: UpdateStickerBodyStatus = archived ? .archived : .active
        let body: JsonObject = ["status": .string(status.rawValue)]
        patch(id) { $0 = $0.applyPatch(body) }
        let sent = try await send(.stickerToggle, id, body, revert: { try? await refresh() }) { () async throws(ApiError) in
            _ = try await api.patch("/api/stickers/\(id)", UpdateStickerBody(status: status), as: Ignored.self)
        }
        if sent == .now { try? await refresh() }
        return sent
    }

    /// Permanent: the bird's finds go with it, out of everyone's collection.
    @discardableResult
    public func delete(_ id: String) async throws(ApiError) -> Sent {
        stickers = stickers?.filter { $0.id != id }
        let sent = try await send(.stickerDelete, id, [:], revert: { try? await refresh() }) { () async throws(ApiError) in
            _ = try await api.delete("/api/stickers/\(id)", as: Ignored.self)
        }
        if sent == .now { try? await refresh() }
        return sent
    }

    /// Texts or position of an own bird (web: EditStickerSheet#submit). [body] comes
    /// from [editPatch]; a parked edit is replayed with its capture time, which the
    /// server checks the 5-minute window against.
    @discardableResult
    public func edit(_ id: String, body: JsonObject) async throws(ApiError) -> Sent {
        patch(id) { $0 = $0.applyPatch(body) }
        let sent = try await send(.stickerEdit, id, body, revert: { try? await refresh() }) { () async throws(ApiError) in
            try await api.patch("/api/stickers/\(id)", json: body)
        }
        if sent == .now { try? await refresh() }
        return sent
    }
}
