import Foundation
import Observation
import OiseauCore

/// Where the app talks to, from the build configuration (project.yml: API_BASE_URL).
enum AppConfig {
    static var apiBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "OPApiBaseURL") as? String ?? "https://oiseaupourri.ch"
        return URL(string: raw) ?? URL(string: "https://oiseaupourri.ch")!
    }

    /// The web app, where the legal texts live.
    static var webBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "OPWebBaseURL") as? String ?? "https://oiseaupourri.ch"
        return URL(string: raw) ?? URL(string: "https://oiseaupourri.ch")!
    }

    static let arguments = ProcessInfo.processInfo.arguments

    /// `-stubApi`: talk to the in-memory StubServer (CI screenshots and the UI test).
    static var stubApi: Bool { arguments.contains("-stubApi") }

    /// `-resetState`: start signed out, nothing kept from a previous run.
    static var resetState: Bool { arguments.contains("-resetState") }
}

/// The version of the terms the sign-up checkbox accepts (Android: domain/FirstRun.kt).
let currentTermsVersion = "2026-07-05"

/// The app's state, shared by every screen (Android: AppViewModel + AppContainer).
@MainActor
@Observable
final class AppModel {
    private(set) var session: SessionState = .unknown
    private(set) var stickers: [MapSticker]?
    /// Why the map's birds couldn't be refreshed (shown over the map), nil when fine.
    var mapError: UiText?
    var filters = MapFilters()

    @ObservationIgnored let api: ApiClient
    @ObservationIgnored let auth: AuthRepository
    @ObservationIgnored let map: MapRepository
    @ObservationIgnored private var started = false

    init(api: ApiClient, userCache: UserCache, snapshot: URL?) {
        self.api = api
        auth = AuthRepository(api: api, userCache: userCache)
        map = MapRepository(api: api, snapshot: snapshot)
        auth.onStateChange = { [weak self] in self?.sessionChanged($0) }
        map.onChange = { [weak self] in self?.stickers = $0 }
    }

    static func live() -> AppModel {
        let snapshot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("map.json")
        let cookies = KeychainCookieStore()
        let users = DefaultsUserCache()
        if AppConfig.resetState {
            cookies.save([])
            users.save(nil)
            try? FileManager.default.removeItem(at: snapshot)
        }
        let stub = AppConfig.stubApi
        let api = ApiClient(
            baseURL: stub ? URL(string: "https://stub.oiseaupourri.test")! : AppConfig.apiBaseURL,
            cookieJar: SessionCookieJar(store: cookies),
            transport: stub ? StubServer() : URLSessionTransport()
        )
        return AppModel(api: api, userCache: users, snapshot: snapshot)
    }

    /// For previews and screenshot tests: a stub server, nothing on disk.
    static func preview(signedIn: Bool = false) -> AppModel {
        let model = AppModel(
            api: ApiClient(baseURL: URL(string: "https://stub.oiseaupourri.test")!, cookieJar: SessionCookieJar(store: MemoryCookieStore()), transport: StubServer(latency: 0)),
            userCache: MemoryUserCache(),
            snapshot: nil
        )
        if signedIn {
            model.session = .signedIn(AuthUser(id: "u-me", email: StubServer.email, name: "alice"))
            model.stickers = SampleStickers.all
        }
        return model
    }

    /// Once, at launch: the stored session (opens at once from the last known player).
    func start() async {
        guard !started else { return }
        started = true
        await auth.restore()
    }

    private func sessionChanged(_ new: SessionState) {
        let before = session
        session = new
        switch new {
        case .signedIn(let user, _):
            if before.user?.id != user.id { Task { await refreshMap() } }
        case .signedOut:
            // Only a real sign-out or a refused session gets here (issue #89): never a failed check.
            map.clear()
            mapError = nil
        case .unknown:
            break
        }
    }

    func refreshMap(force: Bool = false) async {
        do {
            if force { try await map.refresh() } else { try await map.refreshIfStale() }
            mapError = nil
        } catch {
            mapError = uiText(error)
        }
    }

    var visibleStickers: [MapSticker] { filters.apply(stickers ?? []) }

    func signOut() async {
        await auth.signOut()
    }

    /// Records the terms the sign-up checkbox accepted, before the app learns it is
    /// signed in (AuthRepository.signUp's hook), so the new account is never asked again.
    func acceptTerms() async {
        _ = try? await api.patch("/api/me/prefs", UpdatePrefsBody(termsAcceptedVersion: currentTermsVersion), as: Ignored.self)
    }
}
