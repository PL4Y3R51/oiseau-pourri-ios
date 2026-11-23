import Foundation

// Offline map zones (issue #89; Android: domain/OfflineMaps.kt): the basemap is the
// one thing that can't be played without a network, so the player can keep zones of
// it on the phone — framed by hand in Réglages, and one kept automatically around
// where the app is mostly opened. Vector tiles from OpenFreeMap (free, keyless,
// donation-funded): the limits below keep both the phone and that service comfortable.

/// A rectangle on the map, south-west to north-east.
public struct GeoBounds: Hashable, Sendable, Codable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }
}

/// How much detail a zone keeps: a district down to the street, or a whole town.
public enum ZoneDetail: String, Sendable, Codable, CaseIterable {
    /// Streets, paths and buildings: what finding a bird needs.
    case quartier = "Quartier"
    /// Roads and places, to find your way to the birds.
    case ville = "Ville"

    public var maxZoom: Int { self == .quartier ? 16 : 14 }
}

/// Below this zoom a zone adds little and costs nothing: always included.
public let zoneMinZoom = 10
/// All zones together, automatic one included.
public let zonesMaxBytes: Int64 = 150 * 1024 * 1024
/// An average OpenFreeMap vector tile, a little on the generous side.
public let avgTileBytes: Int64 = 30 * 1024
/// The style, its fonts and its sprites, fetched once per zone.
public let styleOverheadBytes: Int64 = 2 * 1024 * 1024
/// The automatic zone's radius around home.
public let autoZoneRadiusM = 3_000.0
/// A home that moved less than this keeps its zone.
public let autoZoneMoveM = 1_000.0
/// How often the automatic zone is refreshed (tiles change, slowly).
public let autoZoneRefreshDays = 30
/// Launch positions kept to place "home"; on the device only, never sent.
public let homeSamplesMax = 20

private func tileX(_ lng: Double, _ z: Int) -> Int { Int(((lng + 180) / 360 * Double(1 << z)).rounded(.down)) }

private func tileY(_ lat: Double, _ z: Int) -> Int {
    let r = min(max(lat, -85.05112878), 85.05112878) * .pi / 180
    return Int(((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * Double(1 << z)).rounded(.down))
}

/// How many tiles cover [b] from [minZoom] to [maxZoom] (the slippy-map grid).
public func tileCount(_ b: GeoBounds, minZoom: Int, maxZoom: Int) -> Int64 {
    (minZoom...maxZoom).reduce(Int64(0)) { sum, z in
        let xs = tileX(b.east, z) - tileX(b.west, z) + 1
        let ys = tileY(b.south, z) - tileY(b.north, z) + 1
        return sum + Int64(xs) * Int64(ys)
    }
}

/// What a zone should weigh once downloaded: shown before the player commits to it.
public func estimateZoneBytes(_ b: GeoBounds, _ detail: ZoneDetail) -> Int64 {
    tileCount(b, minZoom: zoneMinZoom, maxZoom: detail.maxZoom) * avgTileBytes + styleOverheadBytes
}

/// Whether a new zone of [estimate] still fits with the [used] bytes of the zones kept.
public func fitsInBudget(used: Int64, estimate: Int64) -> Bool { used + estimate <= zonesMaxBytes }

/// A square of [radiusM] around [center] (good enough at our latitudes).
public func boundsAround(_ center: GeoPoint, radiusM: Double) -> GeoBounds {
    let dLat = radiusM / 111_320
    let dLng = radiusM / (111_320 * cos(center.lat * .pi / 180))
    return GeoBounds(south: center.lat - dLat, west: center.lng - dLng, north: center.lat + dLat, east: center.lng + dLng)
}

/// Where the app is mostly opened: the median of the launch positions kept — a
/// median, so a holiday or a trip across town doesn't drag "home" around. Nil until
/// there are a few.
public func homeCenter(_ samples: [GeoPoint]) -> GeoPoint? {
    guard samples.count >= 3 else { return nil }
    func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    return GeoPoint(lng: median(samples.map(\.lng)), lat: median(samples.map(\.lat)))
}

/// A launch position as kept: rounded to ~100 m, which is all "home" needs.
public func coarse(_ p: GeoPoint) -> GeoPoint {
    // Half away from zero for the positive coordinates we have; Java's Math.round is half up.
    GeoPoint(lng: (p.lng * 1000).rounded(.toNearestOrAwayFromZero) / 1000, lat: (p.lat * 1000).rounded(.toNearestOrAwayFromZero) / 1000)
}

/// The launch positions with [p] added (coarse), the last [homeSamplesMax] kept
/// (Android: LocalSettings#addHomeSample).
public func addHomeSample(_ samples: [GeoPoint], _ p: GeoPoint) -> [GeoPoint] {
    Array((samples + [coarse(p)]).suffix(homeSamplesMax))
}

/// What the automatic zone should do now.
public enum AutoZonePlan: Sendable { case nothing, download, replace }

public func planAutoZone(home: GeoPoint?, existingCenter: GeoPoint?, existingAgeDays: Int?, existingStyleMatches: Bool) -> AutoZonePlan {
    guard let home else { return .nothing }
    guard let existingCenter else { return .download }
    if !existingStyleMatches { return .replace }
    if distanceM(home, existingCenter) > autoZoneMoveM { return .replace }
    if (existingAgeDays ?? 0) >= autoZoneRefreshDays { return .replace }
    return .nothing
}

public enum ZoneKind: String, Sendable, Codable { case manual, auto }

/// What the app keeps with each zone (MapLibre's offline pack metadata).
public struct ZoneMeta: Hashable, Sendable, Codable {
    public var name: String
    public var kind: ZoneKind
    /// The OpenFreeMap style id the tiles were fetched for.
    public var styleId: String
    /// Epoch ms.
    public var createdAt: Int64
    public var detail: ZoneDetail
    /// The automatic zone's home, to tell whether it moved.
    public var centerLng: Double?
    public var centerLat: Double?

    public init(name: String, kind: ZoneKind, styleId: String, createdAt: Int64, detail: ZoneDetail = .quartier, centerLng: Double? = nil, centerLat: Double? = nil) {
        self.name = name
        self.kind = kind
        self.styleId = styleId
        self.createdAt = createdAt
        self.detail = detail
        self.centerLng = centerLng
        self.centerLat = centerLat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ZoneKind.self, forKey: .kind)
        styleId = try c.decode(String.self, forKey: .styleId)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        detail = try c.decodeIfPresent(ZoneDetail.self, forKey: .detail) ?? .quartier
        centerLng = try c.decodeIfPresent(Double.self, forKey: .centerLng)
        centerLat = try c.decodeIfPresent(Double.self, forKey: .centerLat)
    }

    public var center: GeoPoint? {
        guard let centerLng, let centerLat else { return nil }
        return GeoPoint(lng: centerLng, lat: centerLat)
    }
}
