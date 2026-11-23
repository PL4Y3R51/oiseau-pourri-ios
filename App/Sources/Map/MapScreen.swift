import SwiftUI
import OiseauCore

/// What the bird sheet shows: one bird, or the birds stacked under a tap.
enum MapSelection: Identifiable {
    case one(String)
    case stack([MapSticker])

    var id: String {
        switch self {
        case .one(let id): return id
        case .stack(let list): return list.map(\.id).joined(separator: ",")
        }
    }
}

/// The map tab (Android: ui/map/MapScreen.kt): the birds, their sheet and its actions,
/// the find and report flows, filters and wishlist, locate me, what waits to sync.
struct MapScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(LocationService.self) private var location
    @State private var selection: MapSelection?
    @State private var locateRequest = 0
    @State private var focus: GeoPoint?
    @State private var hunt: HuntModel?
    @State private var editing: EditTarget?
    @State private var deleting: MapSticker?
    @State private var showWishlist = false
    @State private var showQueue = false

    init() {}

    var body: some View {
        ZStack(alignment: .top) {
            BirdMap(
                stickers: app.visibleStickers,
                styleURL: MapStyle.of(app.prefs?.mapStyle).url,
                // No permission prompt in CI: the stub has no player to locate.
                showsUser: location.permitted && !AppConfig.stubApi,
                locateRequest: locateRequest,
                focus: focus,
                onTap: { stack in selection = stack.count == 1 ? .one(stack[0].id) : .stack(stack) }
            )
            .ignoresSafeArea(edges: [.horizontal, .bottom])

            VStack(spacing: 8) {
                PendingSyncBanner(queue: app.myQueue) { showQueue = true }
                if let error = app.mapError {
                    MapNotice(text: error.text) { Task { await app.refreshMap(force: true) } }
                }
                if let toast = app.toast {
                    MapNotice(text: toast.text) { app.toast = nil }
                        .task(id: toast.text) {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            app.toast = nil
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                MapMenu(onWishlist: { showWishlist = true })
                RoundButton(icon: "locate_fixed", label: L("map_locate_me")) {
                    if location.permitted { locateRequest += 1 } else { location.requestPermission() }
                }
            }
            .padding(20)
        }
        .sheet(item: $selection) { sel in
            Group {
                switch sel {
                case .one(let id):
                    if let s = app.stickers?.first(where: { $0.id == id }) { sheet(for: s) }
                case .stack(let list):
                    StickerGallery(stickers: list) { selection = .one($0.id) }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Zine.panel)
        }
        .sheet(item: $hunt) { model in
            HuntSheet(model: model) { hunt = nil }
                .presentationDetents([.large])
                .presentationBackground(Zine.panel)
                .interactiveDismissDisabled(model.busy)
        }
        .sheet(item: $editing) { target in EditStickerView(target: target) }
        .sheet(isPresented: $showWishlist) {
            WishlistSheet { s in
                showWishlist = false
                fly(to: s)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Zine.panel)
        }
        .sheet(isPresented: $showQueue) {
            SyncQueueSheet().presentationDetents([.medium, .large]).presentationBackground(Zine.panel)
        }
        .confirmationDialog(L("delete_title"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("common_delete"), role: .destructive) {
                if let s = deleting { Task { await act { try await app.map.delete(s.id) } } }
                selection = nil
            }
            Button(L("common_cancel"), role: .cancel) {}
        } message: {
            Text(L("delete_body"))
        }
        .task {
            location.requestPermission()
            await app.refreshMap()
        }
        .onChange(of: app.mapFocus) { _, id in
            guard let id, let s = app.stickers?.first(where: { $0.id == id }) else { return }
            app.mapFocus = nil
            fly(to: s)
        }
    }

    private func fly(to s: MapSticker) {
        focus = s.point
        selection = .one(s.id)
    }

    @ViewBuilder private func sheet(for s: MapSticker) -> some View {
        StickerSheetView(
            sticker: s,
            onClose: { selection = nil },
            actions: SheetActions(
                onFind: {
                    selection = nil
                    hunt = HuntModel(kind: .find, sticker: s, position: location.last)
                },
                onEdit: {
                    selection = nil
                    editing = EditTarget(map: s)
                },
                onAction: { perform($0, on: s) },
                onReveal: { Task { await app.revealSpoiler(s.id) } }
            ),
            hideSpoilers: app.prefs?.hideMapSpoilers ?? false,
            revealed: app.prefs?.revealedSpoilers.contains(s.id) ?? false
        )
    }

    private func perform(_ a: StickerAction, on s: MapSticker) {
        switch a {
        case .openInCollection:
            selection = nil
            app.collectionFocus = (s.id, s.placedByMe)
            app.tab = .collection
        case .report:
            selection = nil
            hunt = HuntModel(kind: .report, sticker: s, position: location.last)
        case .wishlist:
            Task { await act { try await app.map.setWishlisted(s.id, !s.wishlisted) } }
        case .placerProfile:
            selection = nil
            app.push(.profile(userId: s.placedById), on: .leaderboard)
        case .makePrivate:
            Task { await act { try await app.map.setPrivate(s.id, !s.isPrivate) } }
        case .archive:
            Task { await act { try await app.map.setArchived(s.id, s.status != .archived) } }
        case .delete:
            deleting = s
        }
    }

    /// A change of a bird: shown at once; a refusal is said over the map.
    private func act(_ change: () async throws -> Sent) async {
        do { _ = try await change() } catch { app.toast = uiText(error) }
    }
}

/// The map's menu: what to show, and the wishlist. A native menu, the iOS way.
private struct MapMenu: View {
    @Environment(AppModel.self) private var app
    let onWishlist: () -> Void

    var body: some View {
        @Bindable var app = app
        let all = app.stickers ?? []
        Menu {
            Button(action: onWishlist) {
                Label { Text(L("map_wishlist")) } icon: { Image("lucide_star") }
            }
            Section(L("map_filters_title")) {
                let rows = filterRows(all, app.filters)
                if rows.isEmpty { Text(L("map_filters_empty")) }
                ForEach(rows, id: \.filter) { row in
                    Toggle("\(L(row.filter.labelKey)) (\(row.count))", isOn: Binding(
                        get: { app.filters.active.contains(row.filter) },
                        set: { _ in app.filters = app.filters.toggled(row.filter) }
                    ))
                }
            }
            Section {
                Toggle(L("map_show_private"), isOn: $app.filters.showPrivate)
                Toggle(L("map_show_archived"), isOn: $app.filters.showArchived)
                if app.filters.deviations > 0 {
                    Button(L("map_filters_reset")) { app.filters = MapFilters() }
                }
            }
        } label: {
            LucideIcon("sliders_horizontal", size: 22)
                .foregroundStyle(Zine.ink)
                .frame(width: 48, height: 48)
                .background(app.filters.deviations > 0 ? Zine.pink : Zine.panel)
                .relief(Circle())
                .overlay(alignment: .topTrailing) {
                    if app.filters.deviations > 0 {
                        Text("\(app.filters.deviations)").font(.syne(11, 800)).foregroundStyle(Zine.yellow)
                            .frame(minWidth: 18, minHeight: 18).background(Zine.ink, in: Capsule()).offset(x: 4, y: -4)
                    }
                }
        }
        .accessibilityLabel(L("map_menu"))
        .accessibilityIdentifier("map.menu")
    }
}

/// The wishlist: a tap flies to the bird and opens it.
private struct WishlistSheet: View {
    @Environment(AppModel.self) private var app
    let onPick: (MapSticker) -> Void

    var body: some View {
        let wished = (app.stickers ?? []).filter(\.wishlisted)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    LucideIcon("star", size: 20)
                    Text(L("map_wishlist")).font(.zTitleLarge)
                }
                .foregroundStyle(Zine.ink)
                if wished.isEmpty {
                    EmptyStateView(text: L("map_wishlist_empty"), pose: .search)
                } else {
                    StickerGallery(stickers: wished, onPick: onPick)
                }
            }
            .padding(20)
        }
    }
}

/// A round floating button in relief (the map's FABs).
struct RoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: 22)
                .foregroundStyle(Zine.ink)
                .frame(width: 48, height: 48)
                .background(Zine.panel)
        }
        .buttonStyle(PressedRelief(shape: Circle()))
        .accessibilityLabel(label)
    }
}

/// Relief that sinks while pressed, for any shape.
struct PressedRelief<S: Shape>: ButtonStyle {
    let shape: S
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.relief(shape, sunk: configuration.isPressed)
    }
}

/// A message over the map, with a way to act on it (retry, dismiss).
private struct MapNotice: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LucideIcon("refresh_cw", size: 16)
                Text(text).font(.zBodySmall).multilineTextAlignment(.leading)
            }
            .foregroundStyle(Zine.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Zine.panel)
        }
        .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
        .accessibilityIdentifier("map.notice")
    }
}

extension EditTarget: Identifiable {
    var id: String { stickerId }
}
