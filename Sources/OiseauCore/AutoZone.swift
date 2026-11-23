import Foundation

/// One offline zone as the map's offline storage reports it.
public struct OfflineZone: Hashable, Sendable {
    public var id: String
    public var meta: ZoneMeta
    /// What it takes on the phone.
    public var bytes: Int64

    public init(id: String, meta: ZoneMeta, bytes: Int64) {
        self.id = id
        self.meta = meta
        self.bytes = bytes
    }
}

/// The map's offline storage (MapLibre's offline packs in the app).
@MainActor
public protocol OfflineZoneStore: AnyObject {
    func list() async -> [OfflineZone]
    func delete(_ id: String) async
    /// Downloads the tiles of [bounds] up to [maxZoom] for [styleURL]; throws when it failed.
    func download(_ meta: ZoneMeta, styleURL: URL, bounds: GeoBounds, maxZoom: Int) async throws
}

/// The « Autour de chez toi » zone (issue #89; Android: sync/AutoZone.kt): ~3 km of
/// map around where the app is mostly opened, kept up to date without the player
/// thinking about it. When it runs (Wi-Fi, battery not low, once a day at most) is
/// the app's scheduling; this decides and does: download only when [planAutoZone]
/// says so (none yet, home moved, other style, a month old), and only within what
/// the player's own zones leave of the budget.
@MainActor
public final class AutoZone {
    private let enabled: () -> Bool
    private let homeSamples: () -> [GeoPoint]
    private let mapStyle: () -> MapStyle
    private let store: any OfflineZoneStore
    private let clock: () -> Date

    public init(enabled: @escaping () -> Bool, homeSamples: @escaping () -> [GeoPoint], mapStyle: @escaping () -> MapStyle, store: any OfflineZoneStore, clock: @escaping () -> Date = Date.init) {
        self.enabled = enabled
        self.homeSamples = homeSamples
        self.mapStyle = mapStyle
        self.store = store
        self.clock = clock
    }

    /// What it did, for tests and logs.
    @discardableResult
    public func run() async throws -> AutoZonePlan {
        guard enabled(), let home = homeCenter(homeSamples()) else { return .nothing }
        let style = mapStyle()
        let zones = await store.list()
        let auto = zones.first { $0.meta.kind == .auto }
        let ageDays = auto.map { Int((clock().timeIntervalSince(dateOf(epochMs: $0.meta.createdAt)) / 86_400).rounded(.down)) }
        let plan = planAutoZone(home: home, existingCenter: auto?.meta.center, existingAgeDays: ageDays, existingStyleMatches: auto?.meta.styleId == style.rawValue)
        if plan == .nothing { return .nothing }

        let bounds = boundsAround(home, radiusM: autoZoneRadiusM)
        let others = zones.filter { $0.id != auto?.id }.reduce(Int64(0)) { $0 + $1.bytes }
        // The player's own zones come first: the automatic one only takes what is left.
        guard fitsInBudget(used: others, estimate: estimateZoneBytes(bounds, .quartier)) else { return .nothing }
        if let auto { await store.delete(auto.id) }
        let meta = ZoneMeta(
            name: "", kind: .auto, styleId: style.rawValue, createdAt: epochMs(clock()),
            detail: .quartier, centerLng: home.lng, centerLat: home.lat
        )
        try await store.download(meta, styleURL: style.url, bounds: bounds, maxZoom: ZoneDetail.quartier.maxZoom)
        return plan
    }
}
