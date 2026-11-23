import SwiftUI
import MapLibre
import OiseauCore

/// The fine-tune map of the place form and the edit sheet (Android: ui/place/PlacementMap.kt).
/// The target is whatever sits under the fixed pin in the middle: pan the map to move
/// it. Each time the map comes to rest the target is held inside the allowed circle
/// around [center] — snapping back if dragged past the edge — and reported. Birds
/// already there are drawn read-only, so a new one doesn't land on top of them.
struct PlacementMap: UIViewRepresentable {
    let styleURL: URL
    /// The device position (placing) or the bird's original spot (editing).
    let center: GeoPoint
    /// The target to open on.
    let initial: GeoPoint
    var radiusM: Double = maxPlacementAdjustM
    var nearby: [MapSticker] = []
    let onChange: (GeoPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.setCenter(CLLocationCoordinate2D(latitude: initial.lat, longitude: initial.lng), zoomLevel: 17, animated: false)
        view.minimumZoomLevel = 14
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.accessibilityIdentifier = "placement.map"
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(on: view)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: PlacementMap
        private var loaded = false

        init(_ parent: PlacementMap) { self.parent = parent }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            for pin in PinStyle.all { style.setImage(PinRenderer.image(pin), forName: pin.spriteId) }
            let ring = circleRing(parent.center, radiusM: parent.radiusM).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            let circle = MLNPolygonFeature(coordinates: ring, count: UInt(ring.count))
            let circleSource = MLNShapeSource(identifier: "allowed", shape: circle, options: nil)
            style.addSource(circleSource)
            let fill = MLNFillStyleLayer(identifier: "allowed-fill", source: circleSource)
            fill.fillColor = NSExpression(forConstantValue: UIColor(hex: 0xFF5FA2))
            fill.fillOpacity = NSExpression(forConstantValue: 0.12)
            style.addLayer(fill)
            let line = MLNLineStyleLayer(identifier: "allowed-line", source: circleSource)
            line.lineColor = NSExpression(forConstantValue: UIColor(hex: 0x111111))
            line.lineWidth = NSExpression(forConstantValue: 1.5)
            line.lineDashPattern = NSExpression(forConstantValue: [2, 2])
            style.addLayer(line)

            let source = MLNShapeSource(identifier: "nearby", features: [], options: nil)
            style.addSource(source)
            let pins = MLNSymbolStyleLayer(identifier: "nearby", source: source)
            pins.iconImageName = NSExpression(forKeyPath: "sprite")
            pins.iconAnchor = NSExpression(forConstantValue: "bottom")
            pins.iconAllowsOverlap = NSExpression(forConstantValue: true)
            pins.iconOpacity = NSExpression(forConstantValue: 0.6)
            style.addLayer(pins)
            loaded = true
            render(on: mapView)
        }

        func render(on view: MLNMapView) {
            guard loaded, let source = view.style?.source(withIdentifier: "nearby") as? MLNShapeSource else { return }
            source.shape = MLNShapeCollectionFeature(shapes: parent.nearby.map { s in
                let f = MLNPointFeature()
                f.coordinate = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lng)
                f.attributes = ["sprite": s.pinStyle.spriteId]
                return f
            })
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            let target = GeoPoint(lng: c.longitude, lat: c.latitude)
            let held = clampToRadius(parent.center, target, maxM: parent.radiusM)
            if held != target {
                mapView.setCenter(CLLocationCoordinate2D(latitude: held.lat, longitude: held.lng), animated: true)
            }
            parent.onChange(held)
        }
    }
}

/// The map with its fixed pin in the middle, framed like a card.
struct PlacementMapCard: View {
    let styleURL: URL
    let center: GeoPoint
    let initial: GeoPoint
    var nearby: [MapSticker] = []
    let onChange: (GeoPoint) -> Void

    var body: some View {
        PlacementMap(styleURL: styleURL, center: center, initial: initial, nearby: nearby, onChange: onChange)
            .overlay {
                // The pin stands on the target: its tip at the centre.
                Image(uiImage: PinRenderer.image(PinStyle(.mine)))
                    .offset(y: -PinRenderer.height / 2 + 3)
                    .allowsHitTesting(false)
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: Zine.radiusMedium))
            .overlay(RoundedRectangle(cornerRadius: Zine.radiusMedium).stroke(Zine.ink, lineWidth: Zine.lineWidth))
    }
}
