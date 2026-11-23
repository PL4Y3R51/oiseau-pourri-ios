import Foundation

public extension UserPrefs {
    /// A brand-new account's prefs: the server's defaults (pinned by the contract fixture).
    static let newAccount = UserPrefs(
        mapStyle: nil, hideMapSpoilers: false, revealedSpoilers: [], onboarded: false,
        termsAcceptedVersion: nil, placementCharterAccepted: false
    )

    /// A prefs PATCH body on prefs, the way the server merges it: arrays replace, scalars merge.
    func merge(_ body: JsonObject?) -> UserPrefs {
        guard let body, let b = body.decoded(as: UpdatePrefsBody.self) else { return self }
        return UserPrefs(
            mapStyle: b.mapStyle ?? mapStyle,
            hideMapSpoilers: b.hideMapSpoilers ?? hideMapSpoilers,
            revealedSpoilers: b.revealedSpoilers ?? revealedSpoilers,
            onboarded: b.onboarded ?? onboarded,
            termsAcceptedVersion: b.termsAcceptedVersion ?? termsAcceptedVersion,
            placementCharterAccepted: b.placementCharterAccepted ?? placementCharterAccepted
        )
    }
}

/// The prefs on disk, with whose they are.
private struct SavedPrefs: Codable {
    var userId: String
    var prefs: UserPrefs
}

/// The account's synced preferences (`/api/me/prefs`; Android: data/PrefsRepository.kt;
/// web: prefs.ts). The server merges a PATCH into what it has — arrays replace,
/// scalars merge — so the app sends only what changed, applied locally first.
///
/// Kept on disk ([file], per account, deleted on sign-out) so an offline launch has
/// them — the charter accepted, the spoilers revealed, the map style — and a change
/// made without a server is parked by the [Outbox] rather than lost (issue #89).
@MainActor
public final class PrefsRepository {
    private let api: ApiClient
    private let file: URL?
    private let outbox: Outbox?
    /// Parked changes, laid on what the server answers until they are sent.
    private let pending: () -> [QueuedAction]
    private let userId: () -> String?

    /// nil until loaded for the signed-in account.
    public private(set) var prefs: UserPrefs? {
        didSet { if prefs != oldValue { onChange?(prefs) } }
    }

    public var onChange: ((UserPrefs?) -> Void)?

    public init(api: ApiClient, file: URL? = nil, outbox: Outbox? = nil, pending: @escaping () -> [QueuedAction] = { [] }, userId: @escaping () -> String? = { nil }) {
        self.api = api
        self.file = file
        self.outbox = outbox
        self.pending = pending
        self.userId = userId
    }

    /// From the server; without one, the copy on disk (and the error is still thrown).
    public func load() async throws(ApiError) {
        let server: UserPrefs
        do {
            server = try await api.get("/api/me/prefs", as: UserPrefs.self) ?? .newAccount
        } catch {
            if error.isUnavailable { loadSaved() }
            throw error
        }
        let user = userId()
        let parked = pending().filter { $0.userId == user && $0.kind == .prefs && $0.status == .pending }
        set(parked.reduce(server) { $0.merge($1.payload) })
    }

    /// The copy on disk, if it is this account's: an offline launch opens with it.
    public func loadSaved() {
        guard prefs == nil, let user = userId(), let file,
              let data = try? Data(contentsOf: file),
              let saved = try? ApiJson.decoder.decode(SavedPrefs.self, from: data),
              saved.userId == user else { return }
        prefs = saved.prefs
    }

    public func clear() {
        prefs = nil
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    @discardableResult
    public func acceptTerms(_ version: String = currentTermsVersion) async throws(ApiError) -> Sent {
        try await update({ $0.termsAcceptedVersion = version }, UpdatePrefsBody(termsAcceptedVersion: version))
    }

    @discardableResult
    public func markOnboarded() async throws(ApiError) -> Sent {
        try await update({ $0.onboarded = true }, UpdatePrefsBody(onboarded: true))
    }

    /// Réglages ▸ Préférences: no spoiler photo on the map at all, not even blurred (synced).
    @discardableResult
    public func setHideSpoilers(_ on: Bool) async throws(ApiError) -> Sent {
        try await update({ $0.hideMapSpoilers = on }, UpdatePrefsBody(hideMapSpoilers: on))
    }

    /// Réglages ▸ Préférences: the basemap (an OpenFreeMap style id), synced like the web.
    @discardableResult
    public func setMapStyle(_ id: String) async throws(ApiError) -> Sent {
        try await update({ $0.mapStyle = id }, UpdatePrefsBody(mapStyle: id))
    }

    /// web: markPlacementCharterAccepted — the charter slides, once per account.
    @discardableResult
    public func acceptPlacementCharter() async throws(ApiError) -> Sent {
        if prefs?.placementCharterAccepted == true { return .now }
        return try await update({ $0.placementCharterAccepted = true }, UpdatePrefsBody(placementCharterAccepted: true))
    }

    /// The placer's spoiler photo stays revealed for this bird, on every device. Arrays
    /// replace wholesale on the server, so the PATCH carries all of them.
    @discardableResult
    public func revealSpoiler(_ stickerId: String) async throws(ApiError) -> Sent {
        let current = prefs ?? .newAccount
        if current.revealedSpoilers.contains(stickerId) { return .now }
        let next = current.revealedSpoilers + [stickerId]
        return try await update({ $0.revealedSpoilers = next }, UpdatePrefsBody(revealedSpoilers: next))
    }

    private func update(_ local: (inout UserPrefs) -> Void, _ body: UpdatePrefsBody) async throws(ApiError) -> Sent {
        var p = prefs ?? .newAccount
        local(&p)
        set(p)
        let call: () async throws(ApiError) -> Void = { [api] () async throws(ApiError) in
            _ = try await api.patch("/api/me/prefs", body, as: Ignored.self)
        }
        guard let outbox else {
            try await call()
            return .now
        }
        return try await outbox.change(.prefs, stickerId: nil, payload: .of(body), send: call)
    }

    private func set(_ p: UserPrefs) {
        prefs = p
        guard let user = userId(), let file, let data = try? ApiJson.encoder.encode(SavedPrefs(userId: user, prefs: p)) else { return }
        _ = writeAtomically(data, to: file)
    }
}
