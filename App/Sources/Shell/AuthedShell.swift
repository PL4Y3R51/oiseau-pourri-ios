import SwiftUI
import OiseauCore

/// The five tabs of the game, in Android's order (Android: ui/OiseauNavigationBar.kt).
/// On iOS: the system tab bar with labels, tinted ink, each tab with its own
/// navigation stack and large title (Android has neither; it's the iOS way).
enum AppTab: Hashable {
    case map, collection, place, leaderboard, profile
}

struct AuthedShell: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Across the top of every screen while the server can't be reached (issue #89).
            ReachabilityBanner(reach: model.reach, collapsed: model.bandClosed, onCollapsed: model.closeBand)
            tabs
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.tab) {
            MapScreen()
                .tabItem { Label { Text(L("tab_map")) } icon: { Image("lucide_map") } }
                .tag(AppTab.map)
            NavigationStack(path: $model.collectionPath) {
                CollectionScreen().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label { Text(L("tab_collection")) } icon: { Image("lucide_trophy") } }
            .tag(AppTab.collection)
            NavigationStack {
                PlaceScreen()
            }
            .tabItem { Label { Text(L("tab_place")) } icon: { Image("lucide_plus") } }
            .tag(AppTab.place)
            NavigationStack(path: $model.leaderboardPath) {
                LeaderboardScreen().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label { Text(L("tab_leaderboard")) } icon: { Image("lucide_medal") } }
            .tag(AppTab.leaderboard)
            NavigationStack(path: $model.profilePath) {
                MyProfileScreen().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label { Text(L("tab_profile")) } icon: { Image("lucide_user_round") } }
            .tag(AppTab.profile)
        }
        .tint(Zine.ink)
    }
}

/// Pages pushed on a tab's stack.
enum Route: Hashable {
    case profile(userId: String)
    case settings
    case preferences
    case account
    case offlineMaps
    case order
    case orderHistory
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .profile(let id): PublicProfileScreen(userId: id)
        case .settings: SettingsScreen()
        case .preferences: PreferencesScreen()
        case .account: AccountScreen()
        case .offlineMaps: OfflineMapsScreen()
        case .order: OrderScreen()
        case .orderHistory: OrderHistoryScreen()
        }
    }
}

/// A picture the API serves (`/api/photos/…`), loaded with the session cookie and
/// kept in memory for the app's life.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [String: UIImage] = [:]

    func image(_ path: String, api: ApiClient) async -> UIImage? {
        if let hit = images[path] { return hit }
        guard let data = try? await api.send("GET", path), let image = UIImage(data: data) else { return nil }
        images[path] = image
        return image
    }
}

/// A player's picture, or the mascot photo when they have none (spec §14).
struct Avatar: View {
    @Environment(AppModel.self) private var model
    let image: String?
    var size: CGFloat = 34
    @State private var loaded: UIImage?

    init(image: String?, size: CGFloat = 34) {
        self.image = image
        self.size = size
    }

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded).resizable().scaledToFill()
            } else {
                Mascotte(.photo)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: image) {
            guard let image, !AppConfig.stubApi else { return }
            loaded = await ImageCache.shared.image(image, api: model.api)
        }
    }
}

/// « Chargement… », centred.
struct LoadingView: View {
    var body: some View {
        Text(L("common_loading")).font(.zBody).foregroundStyle(Zine.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The mascot and a line, when a list has nothing to show.
struct EmptyStateView: View {
    let text: String
    var pose: MascottePose = .sad

    var body: some View {
        VStack(spacing: 12) {
            Mascotte(pose).frame(width: 120, height: 120)
            Text(text).font(.zBody).foregroundStyle(Zine.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// A chip in relief, pink when on (web: .filter-chip).
struct FilterChip: View {
    let label: String
    let on: Bool
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { LucideIcon(icon, size: 14) }
                Text(label).font(.syne(12.5, 700))
            }
            .foregroundStyle(Zine.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(on ? Zine.pink : Zine.panel)
        }
        .buttonStyle(ChipStyle(on: on))
        .frame(minHeight: 44)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private struct ChipStyle: ButtonStyle {
        let on: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.relief(Capsule(), sunk: on || configuration.isPressed)
        }
    }
}

/// A row that leads somewhere, in relief (Android: PressRow).
struct PressRow: View {
    let title: String
    var icon: String?
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { LucideIcon(icon, size: 20) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.zTitle)
                    if let subtitle { Text(subtitle).font(.zBodySmall).foregroundStyle(Zine.muted) }
                }
                Spacer()
                LucideIcon("chevron_right", size: 18).foregroundStyle(Zine.muted)
            }
            .foregroundStyle(Zine.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Zine.panel)
        }
        .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
    }
}

/// « Hors ligne · données du 19.11 à 15:42 » over a screen showing what it kept (issue #89).
struct StaleBanner: View {
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon("cloud_off", size: 16)
            Text(L("stale_banner", since.formatted(date: .numeric, time: .shortened))).font(.zBodySmall)
        }
        .foregroundStyle(Zine.ink)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zine.yellow, in: RoundedRectangle(cornerRadius: Zine.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Zine.radiusSmall).stroke(Zine.ink, lineWidth: Zine.lineWidth))
    }
}
