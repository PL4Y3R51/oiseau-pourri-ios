import SwiftUI
import OiseauCore

/// Réglages ▸ Préférences (Android: ui/settings/PreferencesScreen.kt): the spoiler
/// photos and the basemap, synced with the account.
struct PreferencesScreen: View {
    @Environment(AppModel.self) private var app

    init() {}

    var body: some View {
        let hide = app.prefs?.hideMapSpoilers ?? false
        let style = MapStyle.of(app.prefs?.mapStyle)
        List {
            Section(L("prefs_display")) {
                Toggle(isOn: Binding(get: { hide }, set: { on in Task { await app.updatePrefs(UpdatePrefsBody(hideMapSpoilers: on)) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("prefs_hide_spoilers")).font(.zBodyLarge).foregroundStyle(Zine.ink)
                        Text(L("prefs_hide_spoilers_help")).font(.zBodySmall).foregroundStyle(Zine.muted)
                    }
                }
                .tint(Zine.pink)
                .accessibilityIdentifier("prefs.hideSpoilers")
            }
            Section {
                HStack(spacing: 10) {
                    ForEach(MapStyle.allCases, id: \.self) { s in
                        StyleCard(style: s, selected: s == style) {
                            Task { await app.updatePrefs(UpdatePrefsBody(mapStyle: s.rawValue)) }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.trailing, Zine.pressOffset)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } header: {
                Text(L("prefs_map_style"))
            } footer: {
                Text(L("prefs_map_style_help"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Zine.paper)
        .navigationTitle(L("settings_preferences"))
    }
}

/// The web's map-style swatches: a gradient that evokes each basemap.
private func swatch(_ s: MapStyle) -> LinearGradient {
    let colors: [Color] = switch s {
    case .liberty: [Color(hex: 0xCFE6C2), Color(hex: 0xE8E2CF), Color(hex: 0xA9D3E0)]
    case .bright: [Color(hex: 0xB6E3A1), Color(hex: 0xFFF4C2), Color(hex: 0x8FD0F5)]
    case .positron: [Color(hex: 0xF2F2F2), Color(hex: 0xE0E0E0), Color(hex: 0xCFCFCF)]
    }
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// One basemap, in relief; the chosen one pink and pressed in (spec §14.3).
private struct StyleCard: View {
    let style: MapStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: Zine.radiusSmall)
                    .fill(swatch(style))
                    .aspectRatio(1.4, contentMode: .fit)
                    .overlay {
                        if selected {
                            LucideIcon("check", size: 16).foregroundStyle(Zine.yellow)
                                .frame(width: 26, height: 26).background(Zine.ink, in: Circle())
                        }
                    }
                Text(style.label).font(.syne(14, 700))
                Text(L(style.descriptionKey)).font(.zBodySmall).multilineTextAlignment(.center).lineLimit(3)
            }
            .foregroundStyle(Zine.ink)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(selected ? Zine.pink : Zine.panel)
        }
        .buttonStyle(Sunk(on: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private struct Sunk: ButtonStyle {
        let on: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.relief(RoundedRectangle(cornerRadius: Zine.radiusMedium), sunk: on || configuration.isPressed)
        }
    }
}
