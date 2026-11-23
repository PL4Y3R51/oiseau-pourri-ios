import SwiftUI
import OiseauCore

/// What the bird sheet shows: one bird, or the birds stacked under a tap.
enum MapSelection: Identifiable {
    case one(MapSticker)
    case stack([MapSticker])

    var id: String {
        switch self {
        case .one(let s): return s.id
        case .stack(let list): return list.map(\.id).joined(separator: ",")
        }
    }
}

/// The map tab, read-only in this step: the birds, their sheet, locate me, sign out.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MapSelection?
    @State private var locateRequest = 0
    @State private var confirmSignOut = false
    @Environment(\.scenePhase) private var scenePhase

    init() {}

    var body: some View {
        ZStack(alignment: .top) {
            BirdMap(
                stickers: model.visibleStickers,
                styleURL: MapStyle.liberty.url,
                // No permission prompt in CI: the stub has no player to locate.
                showsUser: !AppConfig.stubApi,
                locateRequest: locateRequest,
                onTap: { stack in selection = stack.count == 1 ? .one(stack[0]) : .stack(stack) }
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    if case .signedIn(_, offline: true) = model.session { OfflineChip() }
                    Spacer()
                    RoundButton(icon: "settings", label: L("settings_sign_out")) { confirmSignOut = true }
                        .accessibilityIdentifier("map.menu")
                }
                if let error = model.mapError {
                    MapNotice(text: error.text) { Task { await model.refreshMap(force: true) } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            if !AppConfig.stubApi {
                RoundButton(icon: "locate_fixed", label: L("map_locate_me")) { locateRequest += 1 }
                    .padding(20)
            }
        }
        .sheet(item: $selection) { selection in
            Group {
                switch selection {
                case .one(let s): StickerSheetView(sticker: s) { self.selection = nil }
                case .stack(let list): StickerGallery(stickers: list) { self.selection = .one($0) }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Zine.panel)
        }
        .confirmationDialog(L("settings_sign_out_title"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(L("settings_sign_out"), role: .destructive) { Task { await model.signOut() } }
                .accessibilityIdentifier("map.signOut")
        } message: {
            Text(L("settings_sign_out_body"))
        }
        .task { await model.refreshMap() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshMap() } }
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

/// « Hors ligne » while the server hasn't confirmed the session (issue #89).
private struct OfflineChip: View {
    var body: some View {
        HStack(spacing: 6) {
            LucideIcon("cloud_off", size: 16)
            Text(L("reach_slim")).font(.zBodySmall).lineLimit(1)
        }
        .foregroundStyle(Zine.yellow)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Zine.ink, in: Capsule())
        .accessibilityIdentifier("map.offline")
    }
}

/// Why the birds didn't refresh, with a way to try again.
private struct MapNotice: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
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
