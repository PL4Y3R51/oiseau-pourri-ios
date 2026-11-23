import CoreLocation
import Foundation
import Observation
import OiseauCore

/// The player's position (Android: data/LocationRepository.kt), with "when in use"
/// permission only. [last] is the freshest fix; [current] waits for a recent one.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var last: Position?
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var waiters: [CheckedContinuation<Position?, Never>] = []

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var permitted: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    var denied: Bool { status == .denied || status == .restricted }

    func requestPermission() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func startUpdating() {
        guard permitted else { return }
        manager.startUpdatingLocation()
    }

    func stopUpdating() { manager.stopUpdatingLocation() }

    /// A fix at most [maxAge] old, waiting up to [timeout] for one (web: getCurrentPosition).
    func current(maxAge: TimeInterval = 60, timeout: TimeInterval = 15) async -> Position? {
        if let p = last, Date().timeIntervalSince(p.at) <= maxAge { return p }
        guard permitted else { requestPermission(); return last }
        manager.requestLocation()
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolve(with: self?.last)
            }
        }
    }

    private func resolve(with p: Position?) {
        let pending = waiters
        waiters = []
        for w in pending { w.resume(returning: p) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let p = Position(GeoPoint(lng: l.coordinate.longitude, lat: l.coordinate.latitude), accuracyM: l.horizontalAccuracy, at: l.timestamp)
        Task { @MainActor in
            self.last = p
            self.resolve(with: p)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(with: self.last) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            if self.permitted { manager.startUpdatingLocation() }
        }
    }
}
