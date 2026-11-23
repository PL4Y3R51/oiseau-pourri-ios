import Foundation

/// Both halves of the Collection tab (web: CollectionPage), loaded together.
public struct PlayerCollection: Equatable, Sendable {
    public var found: [CollectionItem]
    public var hidden: [MyPlacedSticker]
    /// Set when the server couldn't be asked: the last answers kept, from then.
    public var staleSince: Date?

    public init(found: [CollectionItem], hidden: [MyPlacedSticker], staleSince: Date? = nil) {
        self.found = found
        self.hidden = hidden
        self.staleSince = staleSince
    }
}

/// The player's collection (Android: data/CollectionRepository.kt): the birds found
/// (`/api/collection`) and the ones placed (`/api/stickers/me`), plus, for an own
/// bird, who found it and its open reports — both placer-only on the server.
/// Lay the parked changes on [PlayerCollection.hidden] with [withPendingPlaced].
@MainActor
public final class CollectionRepository {
    private let api: ApiClient
    private let map: MapRepository
    /// The last answers, shown without a network or a server (issue #89). Nil in tests that don't care.
    private let cache: JsonCache?

    public init(api: ApiClient, map: MapRepository, cache: JsonCache? = nil) {
        self.api = api
        self.map = map
        self.cache = cache
    }

    /// Both halves at once; [PlayerCollection.staleSince] set: the last answers kept.
    public func load() async throws(ApiError) -> PlayerCollection {
        async let found = cached("collection") { [api] () async throws(ApiError) -> [CollectionItem] in
            try await api.get("/api/collection", as: [CollectionItem].self) ?? []
        }
        async let hidden = cached("stickers-me") { [api] () async throws(ApiError) -> [MyPlacedSticker] in
            try await api.get("/api/stickers/me", as: [MyPlacedSticker].self) ?? []
        }
        let f: Fetched<[CollectionItem]>
        let h: Fetched<[MyPlacedSticker]>
        do {
            f = try await found
            h = try await hidden
        } catch let e as ApiError {
            throw e
        } catch {
            throw ApiError(status: 0, code: ApiError.unknown, message: "\(error)")
        }
        return PlayerCollection(found: f.value, hidden: h.value, staleSince: [f.staleSince, h.staleSince].compactMap { $0 }.min())
    }

    private func cached<T: Codable>(_ key: String, _ call: () async throws(ApiError) -> T) async throws(ApiError) -> Fetched<T> {
        if let cache { return try await cache.fetch(key, call) }
        return Fetched(try await call())
    }

    public func hidden() async throws(ApiError) -> [MyPlacedSticker] {
        try await api.get("/api/stickers/me", as: [MyPlacedSticker].self) ?? []
    }

    public func finders(_ stickerId: String) async throws(ApiError) -> [StickerFinder] {
        try await api.get("/api/stickers/\(stickerId)/finders", as: [StickerFinder].self) ?? []
    }

    public func reports(_ stickerId: String) async throws(ApiError) -> [StickerReport] {
        try await api.get("/api/stickers/\(stickerId)/reports", as: [StickerReport].self) ?? []
    }

    /// Decide a missing-report (web: PlacedDetail#decideReport): `accepted` confirms the
    /// bird is gone — the server archives it and rewards the reporter — `resolved` says
    /// it is still there. The map may change: refetched.
    public func decideReport(_ reportId: String, accepted: Bool) async throws(ApiError) {
        _ = try await api.patch("/api/reports/\(reportId)", ResolveReportBody(status: accepted ? .accepted : .resolved), as: Ignored.self)
        try? await map.refresh()
    }
}
