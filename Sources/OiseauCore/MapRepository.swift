import Foundation

/// The birds on the map (`GET /api/map`), the read part of Android's
/// data/MapRepository.kt. Kept in memory so the map paints at once, fetched again
/// once a minute old, and kept on disk so a cold start without a network (or with
/// the API down) still shows the last pins.
@MainActor
public final class MapRepository {
    private let api: ApiClient
    /// The last list fetched, per account; deleted on sign-out ([clear]).
    private let snapshot: URL?
    private let clock: () -> Date

    /// nil until the first load.
    public private(set) var stickers: [MapSticker]? {
        didSet { onChange?(stickers) }
    }

    public var onChange: (([MapSticker]?) -> Void)?

    private var fetchedAt: Date = .distantPast

    public static let staleAfter: TimeInterval = 60

    public init(api: ApiClient, snapshot: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.api = api
        self.snapshot = snapshot
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
        stickers = list
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
        try? FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: snapshot, options: .atomic)
    }

    private func restore() {
        guard let snapshot, let data = try? Data(contentsOf: snapshot),
              let list = try? ApiJson.decoder.decode([MapSticker].self, from: data) else { return }
        // fetchedAt stays in the past: stale, so the next chance at a network refetches it.
        if stickers == nil { stickers = list }
    }
}
