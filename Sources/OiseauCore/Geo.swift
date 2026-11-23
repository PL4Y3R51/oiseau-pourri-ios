import Foundation

/// A WGS84 point, in the API's order (lng, lat). Android: domain/Geo.kt.
public struct GeoPoint: Hashable, Sendable {
    public var lng: Double
    public var lat: Double

    public init(lng: Double, lat: Double) {
        self.lng = lng
        self.lat = lat
    }

    /// Storage form ("lng,lat"), locale-proof.
    public func format() -> String { String(format: "%.7f,%.7f", lng, lat) }

    /// The admin bar's display (web: `lat.toFixed(5), lng.toFixed(5)`).
    public func label() -> String { String(format: "%.5f, %.5f", lat, lng) }

    public static func parse(_ s: String) -> GeoPoint? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let lng = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
        return GeoPoint(lng: lng, lat: lat)
    }

    /// Where the map opens without a position (web MapView: Lausanne).
    public static let lausanne = GeoPoint(lng: 6.6323, lat: 46.5197)
}

public extension MapSticker {
    var point: GeoPoint { GeoPoint(lng: lng, lat: lat) }
}

/// A position fix: where, how precise (metres), and when (Android: domain/Geo.kt Position).
public struct Position: Hashable, Sendable {
    public var point: GeoPoint
    public var accuracyM: Double
    public var at: Date

    public init(_ point: GeoPoint, accuracyM: Double, at: Date = Date(timeIntervalSince1970: 0)) {
        self.point = point
        self.accuracyM = accuracyM
        self.at = at
    }
}

private let earthRadiusM = 6_371_000.0
private func rad(_ d: Double) -> Double { d * .pi / 180 }
private func deg(_ r: Double) -> Double { r * 180 / .pi }

/// How far a placement may be moved from where the player stands (shared MAX_PLACEMENT_ADJUST_M).
public let maxPlacementAdjustM = 100.0

/// Great-circle distance in metres (haversine).
public func distanceM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
    let dLat = rad(b.lat - a.lat)
    let dLng = rad(b.lng - a.lng)
    let h = pow(sin(dLat / 2), 2) + pow(sin(dLng / 2), 2) * cos(rad(a.lat)) * cos(rad(b.lat))
    return 2 * earthRadiusM * asin(min(1, sqrt(h)))
}

/// [point] when within [maxM] of [center], else the point on the circle along the same bearing.
public func clampToRadius(_ center: GeoPoint, _ point: GeoPoint, maxM: Double) -> GeoPoint {
    if distanceM(center, point) <= maxM { return point }
    let phi1 = rad(center.lat), phi2 = rad(point.lat), dLambda = rad(point.lng - center.lng)
    let bearing = atan2(sin(dLambda) * cos(phi2), cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda))
    return destination(center, bearing: bearing, distanceM: maxM)
}

/// The ring of a circle around [center], closed (first point repeated), for a fill layer.
public func circleRing(_ center: GeoPoint, radiusM: Double, points: Int = 64) -> [GeoPoint] {
    (0...points).map { i in destination(center, bearing: 2 * .pi * Double(i) / Double(points), distanceM: radiusM) }
}

private func destination(_ from: GeoPoint, bearing: Double, distanceM: Double) -> GeoPoint {
    let phi1 = rad(from.lat)
    let delta = distanceM / earthRadiusM
    let phi3 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(bearing))
    let lambda3 = rad(from.lng) + atan2(sin(bearing) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi3))
    return GeoPoint(lng: (deg(lambda3) + 540).truncatingRemainder(dividingBy: 360) - 180, lat: deg(phi3))
}

/// OpenFreeMap styles; `prefs.mapStyle` picks one, Liberty by default.
public enum MapStyle: String, CaseIterable, Sendable {
    case liberty, bright, positron

    public var url: URL { URL(string: "https://tiles.openfreemap.org/styles/\(rawValue)")! }

    /// OpenFreeMap's own names, not translated.
    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var descriptionKey: String { "map_style_\(rawValue)" }

    public static func of(_ id: String?) -> MapStyle { id.flatMap(MapStyle.init(rawValue:)) ?? .liberty }
}
