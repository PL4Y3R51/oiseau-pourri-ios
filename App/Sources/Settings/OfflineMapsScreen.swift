import SwiftUI
import MapLibre
import Observation
import OiseauCore

// Réglages ▸ Cartes hors ligne (Android: ui/settings/OfflineMapsScreen.kt, data/OfflineMaps.kt):
// zones of map kept on the phone, framed by hand or kept around home, on MapLibre's
// offline packs. The rules (sizes, budget, the home zone's plan) are OiseauCore's.

/// The zones, as MapLibre offline packs; a pack's context is its ZoneMeta in JSON.
@MainActor
final class MapLibreZoneStore: OfflineZoneStore {
    static let shared = MapLibreZoneStore()
    /// Download progress per zone id, 0...1.
    var onProgress: ((String, Double) -> Void)?

    private func meta(_ pack: MLNOfflinePack) -> ZoneMeta? {
        try? JSONDecoder().decode(ZoneMeta.self, from: pack.context)
    }

    private func id(_ pack: MLNOfflinePack) -> String {
        meta(pack).map { "\($0.kind.rawValue)-\($0.createdAt)" } ?? UUID().uuidString
    }

    func list() async -> [OfflineZone] {
        (MLNOfflineStorage.shared.packs ?? []).compactMap { pack in
            guard let m = meta(pack) else { return nil }
            return OfflineZone(id: id(pack), meta: m, bytes: Int64(pack.progress.countOfBytesCompleted))
        }
    }

    /// Whether a zone's download finished.
    func complete(_ zoneId: String) -> Bool {
        (MLNOfflineStorage.shared.packs ?? []).first { id($0) == zoneId }.map { $0.state == .complete } ?? false
    }

    func delete(_ zoneId: String) async {
        guard let pack = (MLNOfflineStorage.shared.packs ?? []).first(where: { id($0) == zoneId }) else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            MLNOfflineStorage.shared.removePack(pack) { _ in c.resume() }
        }
    }

    func download(_ meta: ZoneMeta, styleURL: URL, bounds: GeoBounds, maxZoom: Int) async throws {
        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.west),
                ne: CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.east)
            ),
            fromZoomLevel: Double(zoneMinZoom),
            toZoomLevel: Double(maxZoom)
        )
        let context = try JSONEncoder().encode(meta)
        let zoneId = "\(meta.kind.rawValue)-\(meta.createdAt)"
        let pack: MLNOfflinePack = try await withCheckedThrowingContinuation { c in
            MLNOfflineStorage.shared.addPack(for: region, withContext: context) { pack, error in
                if let pack { c.resume(returning: pack) } else { c.resume(throwing: error ?? TransportFailure("no pack")) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            var observers: [NSObjectProtocol] = []
            let finish: (Error?) -> Void = { error in
                guard !done else { return }
                done = true
                observers.forEach(NotificationCenter.default.removeObserver)
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
            observers.append(NotificationCenter.default.addObserver(forName: .MLNOfflinePackProgressChanged, object: pack, queue: .main) { [weak self] _ in
                let p = pack.progress
                let total = max(p.countOfResourcesExpected, 1)
                MainActor.assumeIsolated { self?.onProgress?(zoneId, Double(p.countOfResourcesCompleted) / Double(total)) }
                if pack.state == .complete { finish(nil) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .MLNOfflinePackError, object: pack, queue: .main) { note in
                finish((note.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error) ?? TransportFailure("offline pack error"))
            })
            pack.resume()
        }
    }
}

/// The automatic home zone: where the app is opened, kept on the device only.
@MainActor
enum HomeZone {
    private static let samplesKey = "offline.homeSamples"
    private static let enabledKey = "offline.auto"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var samples: [GeoPoint] {
        (UserDefaults.standard.array(forKey: samplesKey) as? [String] ?? []).compactMap(GeoPoint.parse)
    }

    /// A launch position, rounded (never sent anywhere; cleared on sign-out).
    static func record(_ p: GeoPoint) {
        UserDefaults.standard.set(addHomeSample(samples, coarse(p)).map { $0.format() }, forKey: samplesKey)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: samplesKey) }

    /// Keeps « Autour de chez toi » up to date; on a network that isn't metered only.
    static func run(style: MapStyle) async {
        guard enabled, !AppConfig.stubApi else { return }
        let zone = AutoZone(enabled: { enabled }, homeSamples: { samples }, mapStyle: { style }, store: MapLibreZoneStore.shared)
        _ = try? await zone.run()
    }
}

@MainActor
@Observable
final class OfflineMapsModel {
    private(set) var zones: [OfflineZone] = []
    private(set) var progress: [String: Double] = [:]
    var error: UiText?
    var auto = HomeZone.enabled { didSet { HomeZone.enabled = auto } }

    var used: Int64 { zones.reduce(0) { $0 + $1.bytes } }

    func load() async {
        MapLibreZoneStore.shared.onProgress = { [weak self] id, p in self?.progress[id] = p }
        zones = await MapLibreZoneStore.shared.list().sorted { $0.meta.createdAt > $1.meta.createdAt }
    }

    func delete(_ z: OfflineZone) async {
        await MapLibreZoneStore.shared.delete(z.id)
        await load()
    }

    func download(name: String, bounds: GeoBounds, detail: ZoneDetail, style: MapStyle) async {
        let meta = ZoneMeta(name: name, kind: .manual, styleId: style.rawValue, createdAt: epochMs(Date()), detail: detail)
        error = nil
        let task = Task { try await MapLibreZoneStore.shared.download(meta, styleURL: style.url, bounds: bounds, maxZoom: detail.maxZoom) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await load()
        do { try await task.value } catch { self.error = .of("offline_maps_failed") }
        await load()
    }
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

struct OfflineMapsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = OfflineMapsModel()
    @State private var framing = false

    init() {}

    var body: some View {
        @Bindable var model = model
        let style = MapStyle.of(app.prefs?.mapStyle)
        List {
            Section {
                Text(L("offline_maps_intro")).font(.zBody).foregroundStyle(Zine.muted)
                Text(L("offline_maps_budget", formatBytes(model.used), formatBytes(zonesMaxBytes))).font(.syne(14, 700))
            }
            Section {
                Toggle(isOn: $model.auto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("offline_maps_auto")).font(.zBodyLarge)
                        Text(L("offline_maps_auto_help")).font(.zBodySmall).foregroundStyle(Zine.muted)
                    }
                }
                .tint(Zine.pink)
            } header: {
                Text(L("offline_maps_auto_title"))
            }
            Section(L("offline_maps_zones")) {
                if model.zones.isEmpty { Text(L("offline_maps_none")).font(.zBody).foregroundStyle(Zine.muted) }
                ForEach(model.zones, id: \.id) { z in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(z.meta.kind == .auto ? L("offline_maps_auto_name") : z.meta.name).font(.syne(15, 700))
                        Text(L("offline_maps_zone_meta",
                               formatBytes(z.bytes),
                               L(z.meta.detail == .quartier ? "offline_maps_detail_quartier" : "offline_maps_detail_ville"),
                               dateOf(epochMs: z.meta.createdAt).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appLocale))))
                            .font(.zBodySmall).foregroundStyle(Zine.muted)
                        if let p = model.progress[z.id], p < 1 {
                            ProgressView(value: p).tint(Zine.ink)
                            Text(L("offline_maps_downloading", Int(p * 100))).font(.zBodySmall).foregroundStyle(Zine.muted)
                        } else if !MapLibreZoneStore.shared.complete(z.id) {
                            Text(L("offline_maps_incomplete")).font(.zBodySmall).foregroundStyle(Zine.error)
                        }
                        if z.meta.styleId != style.rawValue {
                            Text(L("offline_maps_other_style", MapStyle.of(z.meta.styleId).label)).font(.zBodySmall).foregroundStyle(Zine.archivedInk)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await model.delete(z) } } label: { Text(L("common_delete")) }
                    }
                }
            }
            if let e = model.error { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }
            Section {
                Button { framing = true } label: {
                    Label { Text(L("offline_maps_add")).font(.syne(16, 700)) } icon: { LucideIcon("plus", size: 18) }
                }
                .foregroundStyle(Zine.ink)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Zine.paper)
        .navigationTitle(L("offline_maps_title"))
        .task { await model.load() }
        .sheet(isPresented: $framing) {
            FrameZoneView(style: style, used: model.used) { name, bounds, detail in
                framing = false
                Task { await model.download(name: name, bounds: bounds, detail: detail, style: style) }
            }
        }
    }
}

/// Framing a zone: everything on screen is kept, at « Quartier » or « Ville » detail.
private struct FrameZoneView: View {
    @Environment(\.dismiss) private var dismiss
    let style: MapStyle
    let used: Int64
    let onDownload: (String, GeoBounds, ZoneDetail) -> Void
    @State private var bounds: GeoBounds?
    @State private var detail: ZoneDetail = .quartier
    @State private var name = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(L("offline_maps_frame")).font(.zBodySmall).foregroundStyle(Zine.muted).padding(.horizontal, 16)
                BoundsMap(styleURL: style.url) { bounds = $0 }
                    .clipShape(RoundedRectangle(cornerRadius: Zine.radiusMedium))
                    .overlay(RoundedRectangle(cornerRadius: Zine.radiusMedium).stroke(Zine.ink, lineWidth: Zine.lineWidth))
                    .padding(.horizontal, 16)
                VStack(spacing: 10) {
                    Picker("", selection: $detail) {
                        Text(L("offline_maps_detail_quartier")).tag(ZoneDetail.quartier)
                        Text(L("offline_maps_detail_ville")).tag(ZoneDetail.ville)
                    }
                    .pickerStyle(.segmented)
                    OpTextField(label: L("place_name"), text: $name)
                    if let bounds {
                        let estimate = estimateZoneBytes(bounds, detail)
                        let fits = fitsInBudget(used: used, estimate: estimate)
                        Text(fits ? L("offline_maps_estimate", formatBytes(estimate)) : L("offline_maps_too_big", formatBytes(estimate)))
                            .font(.zBody).foregroundStyle(fits ? Zine.muted : Zine.error)
                        OpButton(title: L("offline_maps_download"), icon: "download", fullWidth: true) {
                            onDownload(name.isEmpty ? L("offline_maps_title") : name, bounds, detail)
                        }
                        .disabled(!fits)
                    }
                }
                .padding(16)
            }
            .background(Zine.paper)
            .navigationTitle(L("offline_maps_add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("common_cancel")) { dismiss() } } }
        }
        .tint(Zine.ink)
    }
}

/// A plain map that reports what it shows.
private struct BoundsMap: UIViewRepresentable {
    let styleURL: URL
    let onBounds: (GeoBounds) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onBounds) }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.setCenter(CLLocationCoordinate2D(latitude: GeoPoint.lausanne.lat, longitude: GeoPoint.lausanne.lng), zoomLevel: 13, animated: false)
        view.showsUserLocation = !AppConfig.stubApi
        view.isRotateEnabled = false
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {}

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let onBounds: (GeoBounds) -> Void
        init(_ onBounds: @escaping (GeoBounds) -> Void) { self.onBounds = onBounds }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let b = mapView.visibleCoordinateBounds
            onBounds(GeoBounds(south: b.sw.latitude, west: b.sw.longitude, north: b.ne.latitude, east: b.ne.longitude))
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            regionDidChange(mapView)
        }

        private func regionDidChange(_ mapView: MLNMapView) {
            self.mapView(mapView, regionDidChangeAnimated: false)
        }
    }
}
