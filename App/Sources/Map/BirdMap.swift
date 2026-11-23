import SwiftUI
import MapLibre
import OiseauCore

/// The MapLibre map with the birds on it (Android: ui/map/BirdMap.kt): one symbol
/// layer over an OpenFreeMap style, one sprite per pin style, a tap opens the bird
/// (or the gallery when pins are stacked under the finger).
struct BirdMap: UIViewRepresentable {
    var stickers: [MapSticker]
    var styleURL: URL
    var showsUser: Bool
    /// Bumped by the « Me localiser » button: recentre on the player.
    var locateRequest: Int
    var onTap: ([MapSticker]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.setCenter(CLLocationCoordinate2D(latitude: GeoPoint.lausanne.lat, longitude: GeoPoint.lausanne.lng), zoomLevel: 13, animated: false)
        view.showsUserLocation = showsUser
        view.compassViewPosition = .bottomLeft
        view.accessibilityIdentifier = "map"

        // A single tap picks a bird; MapLibre's own double tap (zoom) goes first.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        for recognizer in view.gestureRecognizers ?? [] {
            if let other = recognizer as? UITapGestureRecognizer, other.numberOfTapsRequired == 2 { tap.require(toFail: other) }
        }
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        if view.styleURL != styleURL {
            coordinator.styleLoaded = false
            view.styleURL = styleURL
        }
        if view.showsUserLocation != showsUser { view.showsUserLocation = showsUser }
        if previous.locateRequest != locateRequest, let here = view.userLocation?.location?.coordinate {
            view.setCenter(here, zoomLevel: max(view.zoomLevel, 16), animated: true)
        }
        coordinator.render(on: view)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: BirdMap
        var styleLoaded = false
        private static let source = "birds"
        private static let layer = "birds"

        init(_ parent: BirdMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Sprites belong to a style: register them again on every style load.
            for pin in PinStyle.all { style.setImage(PinRenderer.image(pin), forName: pin.spriteId) }
            let source = MLNShapeSource(identifier: Self.source, features: [], options: nil)
            style.addSource(source)
            let layer = MLNSymbolStyleLayer(identifier: Self.layer, source: source)
            layer.iconImageName = NSExpression(forKeyPath: "sprite")
            layer.iconAnchor = NSExpression(forConstantValue: "bottom")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            style.addLayer(layer)
            styleLoaded = true
            render(on: mapView)
        }

        func render(on view: MLNMapView) {
            guard styleLoaded, let source = view.style?.source(withIdentifier: Self.source) as? MLNShapeSource else { return }
            let features: [MLNPointFeature] = parent.stickers.map { s in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng)
                f.attributes = ["id": s.id, "sprite": s.pinStyle.spriteId]
                return f
            }
            source.shape = MLNShapeCollectionFeature(shapes: features)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? MLNMapView, gesture.state == .ended else { return }
            let point = gesture.location(in: view)
            // The pin stands above its anchor: search the drop's box, not just the tip.
            let box = CGRect(x: point.x - PinRenderer.width / 2, y: point.y - 8, width: PinRenderer.width, height: PinRenderer.height)
            let ids = view.visibleFeatures(in: box, styleLayerIdentifiers: [Self.layer])
                .compactMap { $0.attribute(forKey: "id") as? String }
            let visible = parent.stickers
            let project = { (s: MapSticker) -> (x: Double, y: Double) in
                let p = view.convert(CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng), toPointTo: view)
                return (Double(p.x), Double(p.y))
            }
            guard let tapped = visible
                .filter({ ids.contains($0.id) })
                .min(by: { distance(project($0), point) < distance(project($1), point) })
            else { return }
            parent.onTap(stackedWith(tapped, visible, threshold: overlapPoints, project: project))
        }

        private func distance(_ p: (x: Double, y: Double), _ q: CGPoint) -> Double {
            hypot(p.x - Double(q.x), p.y - Double(q.y))
        }
    }
}
