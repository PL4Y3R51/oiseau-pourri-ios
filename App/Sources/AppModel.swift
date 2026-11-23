import Foundation
import Network
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

/// The app's state and services, shared by every screen (Android: AppContainer + AppViewModel).
@MainActor
@Observable
final class AppModel {
    // MARK: State the screens read

    private(set) var session: SessionState = .unknown
    private(set) var stickers: [MapSticker]?
    private(set) var prefs: UserPrefs?
    private(set) var reach: Reach = .online
    private(set) var bandClosed = false
    private(set) var queued: [QueuedAction] = []
    /// Why the map's birds couldn't be refreshed (shown over the map), nil when fine.
    var mapError: UiText?
    var filters = MapFilters()
    /// A short message over the map (« Gardé au chaud », a sync that landed…).
    var toast: UiText?

    // Navigation
    var tab: AppTab = .map
    var collectionPath: [Route] = []
    var leaderboardPath: [Route] = []
    var profilePath: [Route] = []
    /// A bird the map should centre on and open (« Voir sur la carte »).
    var mapFocus: String?
    /// The collection tab should open on this bird.
    var collectionFocus: (id: String, hidden: Bool)?
    /// Bumped when a link inside a collection sheet leads away: the sheet closes.
    var collectionSheetCloseRequest = 0
    /// An e-mail link landed on the account page: what it said.
    var accountLanding: AccountLanding?
    /// A password-reset link was opened (signed out): its token, "" when the link had none.
    var resetToken: String?

    // MARK: Services

    @ObservationIgnored let api: ApiClient
    @ObservationIgnored let auth: AuthRepository
    @ObservationIgnored let reachability: Reachability
    @ObservationIgnored let queue: OfflineQueue
    @ObservationIgnored private(set) var outbox: Outbox!
    @ObservationIgnored private(set) var map: MapRepository!
    @ObservationIgnored private(set) var prefsRepo: PrefsRepository!
    @ObservationIgnored let cache: JsonCache
    @ObservationIgnored private(set) var hunt: HuntRepository!
    @ObservationIgnored private(set) var place: PlaceRepository!
    @ObservationIgnored private(set) var collection: CollectionRepository!
    @ObservationIgnored private(set) var account: AccountRepository!
    @ObservationIgnored private(set) var sync: OfflineSync!
    @ObservationIgnored let photoPreparer: PhotoPreparer
    @ObservationIgnored let location = LocationService()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var probing: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?

    init(api: ApiClient, userCache: UserCache, dataDir: URL?, cacheDir: URL?) {
        self.api = api
        auth = AuthRepository(api: api, userCache: userCache)
        reachability = Reachability(networkUp: true)
        let queueDir = dataDir?.appendingPathComponent("queue") ?? FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)")
        queue = OfflineQueue(dir: queueDir)
        cache = JsonCache(root: cacheDir, userId: { [weak auth] in auth?.state.user?.id })
        photoPreparer = ImagePhotoPreparer()

        let userId: () -> String? = { [weak auth] in auth?.state.user?.id }
        outbox = Outbox(
            queue: queue,
            userId: userId,
            knownOffline: { [weak reachability] in reachability?.state == .noNetwork },
            schedule: { BackgroundSync.schedule() },
            drainNow: { [weak self] in await self?.drain() }
        )
        let pending: () -> [QueuedAction] = { [weak queue] in queue?.items ?? [] }
        map = MapRepository(api: api, snapshot: dataDir?.appendingPathComponent("map.json"), outbox: outbox, pending: pending, userId: userId)
        prefsRepo = PrefsRepository(api: api, file: dataDir?.appendingPathComponent("prefs.json"), outbox: outbox, pending: pending, userId: userId)
        hunt = HuntRepository(api: api)
        place = PlaceRepository(api: api, map: map)
        collection = CollectionRepository(api: api, map: map, cache: cache)
        account = AccountRepository(api: api, auth: auth, queue: queue, map: map)
        sync = OfflineSync(queue: queue, sender: ApiQueueSender(api: api, hunt: hunt, place: place), userId: userId, schedule: { BackgroundSync.schedule() })

        auth.onStateChange = { [weak self] in self?.sessionChanged($0) }
        map.onChange = { [weak self] in self?.stickers = $0 }
        prefsRepo.onChange = { [weak self] in self?.prefs = $0 }
        queue.onChange = { [weak self] items in self?.queued = items }
        queued = queue.items
        api.onServerAnswered = { [weak self] answered in self?.reachability.serverAnswered(answered) }
        reachability.onChange = { [weak self] in self?.reachChanged($0) }
        reachability.onBandClosedChange = { [weak self] in self?.bandClosed = $0 }
        sync.onLanded = { [weak self] n in
            guard let self, n > 0 else { return }
            Task { await self.refreshMap(force: true) }
        }
    }

    static func live() -> AppModel {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("oiseau")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("json")
        let cookies = KeychainCookieStore()
        let users = DefaultsUserCache()
        if AppConfig.resetState {
            cookies.save([])
            users.save(nil)
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: caches)
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let stub = AppConfig.stubApi
        let api = ApiClient(
            baseURL: stub ? URL(string: "https://stub.oiseaupourri.test")! : AppConfig.apiBaseURL,
            cookieJar: SessionCookieJar(store: cookies),
            transport: stub ? StubServer() : URLSessionTransport()
        )
        let model = AppModel(api: api, userCache: users, dataDir: support, cacheDir: caches)
        BackgroundSync.app = model
        return model
    }

    /// For previews and screenshot tests: a stub server, nothing kept on disk.
    static func preview(signedIn: Bool = false, prefs: UserPrefs? = nil) -> AppModel {
        let model = AppModel(
            api: ApiClient(baseURL: URL(string: "https://stub.oiseaupourri.test")!, cookieJar: SessionCookieJar(store: MemoryCookieStore()), transport: StubServer(latency: 0)),
            userCache: MemoryUserCache(),
            dataDir: nil,
            cacheDir: nil
        )
        if signedIn {
            model.session = .signedIn(AuthUser(id: "u-me", email: StubServer.email, name: "alice"))
            model.stickers = SampleStickers.all
            model.prefs = prefs ?? StubServer.defaultPrefs
        }
        return model
    }

    // MARK: Lifecycle

    /// Once, at launch: watch the network, then the stored session (opens at once from the last known player).
    func start() async {
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.reachability.networkChanged(up) }
        }
        monitor.start(queue: DispatchQueue(label: "ch.oiseaupourri.network"))
        self.monitor = monitor
        await auth.restore()
    }

    /// Back in the foreground: what may have changed while away.
    func resumed() async {
        guard session.user != nil else { return }
        await refreshMap()
        await drain()
        // Where the app is opened, for « Autour de chez toi » (rounded, on this device only).
        if let p = await location.current(maxAge: 600, timeout: 10) { HomeZone.record(p.point) }
        await HomeZone.run(style: MapStyle.of(prefs?.mapStyle))
    }

    private func sessionChanged(_ new: SessionState) {
        let before = session
        session = new
        switch new {
        case .signedIn(let user, _):
            guard before.user?.id != user.id else { return }
            prefsRepo.loadSaved()
            Task {
                try? await prefsRepo.load()
                await refreshMap()
                await drain()
            }
        case .signedOut:
            // Only a real sign-out or a refused session gets here (issue #89): never a failed check.
            map.clear()
            prefsRepo.clear()
            cache.clear()
            HomeZone.clear()
            mapError = nil
            tab = .map
            collectionPath = []
            leaderboardPath = []
            profilePath = []
        case .unknown:
            break
        }
    }

    private func reachChanged(_ new: Reach) {
        let before = reach
        reach = new
        if new == .online && before != .online {
            // The server is back: confirm the session, send what waited.
            probing?.cancel()
            probing = nil
            Task {
                await auth.revalidate()
                await drain()
                await refreshMap()
            }
        } else if new == .serverDown && probing == nil {
            // Ask again, more and more slowly (15 s → 2 min), until it answers.
            probing = Task { [weak self] in
                var delay: UInt64 = 15
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    await self.auth.revalidate()
                    delay = min(delay * 2, 120)
                }
            }
        }
    }

    func closeBand(_ closed: Bool) { reachability.closeBand(closed) }

    // MARK: Map

    func refreshMap(force: Bool = false) async {
        do {
            if force { try await map.refresh() } else { try await map.refreshIfStale() }
            mapError = nil
        } catch let e as ApiError {
            mapError = e.isUnavailable ? nil : e.toUiText()
        } catch {
            mapError = uiText(error)
        }
    }

    var visibleStickers: [MapSticker] { filters.apply(stickers ?? []) }

    func showOnMap(_ s: MapSticker) {
        mapFocus = s.id
        tab = .map
    }

    func push(_ route: Route, on tab: AppTab) {
        self.tab = tab
        switch tab {
        case .collection: collectionPath.append(route)
        case .leaderboard: leaderboardPath.append(route)
        case .profile: profilePath.append(route)
        default: break
        }
    }

    // MARK: Queue

    /// This player's parked actions.
    var myQueue: [QueuedAction] {
        guard let id = session.user?.id else { return [] }
        return queued.filter { $0.userId == id }
    }

    var pendingCount: Int { myQueue.filter { $0.status == .pending }.count }

    func drain() async {
        _ = await sync.drain()
    }

    func discard(_ action: QueuedAction) {
        queue.discard(action.id)
    }

    // MARK: Prefs

    func updatePrefs(_ change: UpdatePrefsBody) async {
        do {
            if let on = change.hideMapSpoilers { _ = try await prefsRepo.setHideSpoilers(on) }
            if let style = change.mapStyle { _ = try await prefsRepo.setMapStyle(style) }
        } catch {
            toast = uiText(error)
        }
    }

    func revealSpoiler(_ id: String) async {
        _ = try? await prefsRepo.revealSpoiler(id)
    }

    /// Records the terms the sign-up checkbox accepted, before the app learns it is
    /// signed in (AuthRepository.signUp's hook), so the new account is never asked again.
    func acceptTerms() async {
        _ = try? await api.patch("/api/me/prefs", UpdatePrefsBody(termsAcceptedVersion: currentTermsVersion), as: Ignored.self)
    }

    func signOut() async {
        await auth.signOut()
    }

    // MARK: Cache

    /// Fetched now, or the last copy kept on the device when the server can't be asked (issue #89).
    func cached<T: Codable>(_ key: String, _ call: () async throws -> T) async throws -> Fetched<T> {
        try await cache.fetch(key) { () async throws(ApiError) -> T in
            do { return try await call() } catch let e as ApiError { throw e } catch { throw ApiError(status: 0, code: ApiError.unknown, message: "\(error)") }
        }
    }

    /// Same, for an answer that may be empty (`null`).
    func cachedOptional<T: Codable>(_ key: String, _ call: () async throws -> T?) async throws -> T? {
        try await cached(key) { try await call() }.value
    }
}
