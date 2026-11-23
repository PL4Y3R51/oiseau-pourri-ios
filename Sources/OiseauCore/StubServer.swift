import Foundation

/// Birds in every state, for tests, previews and screenshots (Android: ui/map/SampleStickers.kt).
public enum SampleStickers {
    public static let placedAt = "2026-09-20T14:30:00.000Z"

    public static let available = MapSticker(
        id: "s-available", lng: 6.6323, lat: 46.5197, placeName: "Fontaine du Bourg",
        state: .available, status: .active, placedByMe: false, placedById: "u-alice", placedByName: "alice",
        hint: "Sous la margelle, côté lac. Regarde bien en bas !", description: nil, foundAt: nil,
        findPhotoId: nil, placementPhotoId: "p-placement", wishlisted: false, isPrivate: false,
        discoveryRadiusM: nil, placedAt: placedAt
    )

    public static let found: MapSticker = {
        var s = available
        s.id = "s-found"
        s.placeName = "Esplanade de Montbenon"
        s.lng = 6.6270
        s.lat = 46.5205
        s.state = .found
        s.hint = nil
        s.description = "Collé sous le troisième banc en partant du kiosque."
        s.foundAt = "2026-09-28T09:12:00.000Z"
        s.findPhotoId = "p-find"
        return s
    }()

    public static let mine: MapSticker = {
        var s = available
        s.id = "s-mine"
        s.placeName = "Parc de Milan"
        s.lng = 6.6205
        s.lat = 46.5150
        s.state = .found
        s.placedByMe = true
        s.placedById = "u-me"
        s.placedByName = "moi"
        s.hint = "Lampadaire bleu"
        s.description = "Derrière le lampadaire bleu, à hauteur d'yeux."
        s.hasOpenReport = true
        s.hasFinds = true
        s.isPrivate = true
        return s
    }()

    public static let archived: MapSticker = {
        var s = available
        s.id = "s-archived"
        s.placeName = "Gare du Flon"
        s.lng = 6.6290
        s.lat = 46.5210
        s.status = .archived
        s.hint = nil
        return s
    }()

    public static let wished: MapSticker = {
        var s = available
        s.id = "s-wished"
        s.placeName = "Cathédrale"
        s.lng = 6.6355
        s.lat = 46.5228
        s.wishlisted = true
        s.placedById = deletedUserId
        s.placedByName = "Compte supprimé"
        return s
    }()

    public static let all = [available, found, mine, archived, wished]
}

/// A fake API in memory, for the app launched with `-stubApi` (screenshots, the UI
/// test in CI: the simulator there has no API to talk to). One account, the dev
/// seed's: alice@example.com / password123. It keeps what the player does (finds,
/// placements, the wishlist, flags, edits, reports, prefs, orders) for the session,
/// so every screen has realistic content. Rules are the server's in spirit only:
/// no proximity check, no edit window.
public actor StubServer: Transport {
    public enum Mode: Sendable {
        case normal
        /// Every call answers 502, like nginx in front of a dead API.
        case serverDown
    }

    public static let email = "alice@example.com"
    public static let password = "password123"

    /// A player who has been through the welcome and accepted the terms; the
    /// placer's charter still to see.
    public static let defaultPrefs = UserPrefs(
        mapStyle: nil, hideMapSpoilers: false, revealedSpoilers: [], onboarded: true,
        termsAcceptedVersion: currentTermsVersion, placementCharterAccepted: false
    )

    private let mode: Mode
    private let latency: TimeInterval
    private var stickers: [MapSticker]
    private var prefs: UserPrefs
    private var userName = "alice"
    private var finds: [CollectionItem]
    private var finders: [String: [StickerFinder]]
    private var reports: [String: [StickerReport]]
    /// Birds this player reported missing.
    private var reported: Set<String> = []
    private var requests: [StickerRequest]
    /// clientToken → the bird it made: a replayed placement plants one bird.
    private var tokens: [String: String] = [:]
    private var nextId = 1

    public init(mode: Mode = .normal, latency: TimeInterval = 0.2, stickers: [MapSticker] = SampleStickers.all, prefs: UserPrefs = StubServer.defaultPrefs) {
        self.mode = mode
        self.latency = latency
        self.stickers = stickers
        self.prefs = prefs
        finds = stickers.filter { $0.state == .found && !$0.placedByMe }.map { s in
            CollectionItem(
                stickerId: s.id, findId: "f-\(s.id)", foundAt: s.foundAt ?? SampleStickers.placedAt, foundLng: s.lng, foundLat: s.lat,
                findPhotoId: s.findPhotoId ?? "p-find", placeName: s.placeName, hint: s.hint, description: s.description,
                placedById: s.placedById, placedByName: s.placedByName, placementPhotoId: s.placementPhotoId, countryCode: "CH",
                placedAt: s.placedAt, status: s.status
            )
        }
        finders = Dictionary(uniqueKeysWithValues: stickers.filter { $0.placedByMe && $0.hasFinds == true }.map { s in
            (s.id, [
                StickerFinder(userId: "u-bob", displayName: "bob", foundAt: "2026-10-02T17:45:00.000Z", findPhotoId: "p-find-bob"),
                StickerFinder(userId: "u-chloe", displayName: "chloé", foundAt: "2026-10-05T08:10:00.000Z", findPhotoId: "p-find-chloe"),
            ])
        })
        reports = Dictionary(uniqueKeysWithValues: stickers.filter { $0.placedByMe && $0.hasOpenReport == true }.map { s in
            (s.id, [StickerReport(id: "r-\(s.id)", reportedById: "u-bob", reportedByName: "bob", note: "Plus rien sous le lampadaire.", photoId: "p-report", createdAt: "2026-10-12T12:00:00.000Z", status: .open)])
        })
        requests = [
            StickerRequest(id: "o-1", deliveryMode: .post, quantity: 10, address: "Rue du Bourg 1, 1003 Lausanne", status: .sent, createdAt: "2026-08-01T09:00:00.000Z", handledAt: "2026-08-03T10:00:00.000Z"),
        ]
    }

    private static let userId = "u-me"
    private static let cookie = "better-auth.session_token=stub-session.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax"
    private static let gone = "better-auth.session_token=; Max-Age=0; Path=/"
    private static let now = "2026-11-23T10:00:00.000Z"

    private var user: AuthUser { AuthUser(id: Self.userId, email: Self.email, name: userName, emailVerified: true) }

    private func ok<T: Encodable>(_ value: T, status: Int = 200) -> HttpResponse {
        HttpResponse(status: status, body: (try? ApiJson.encoder.encode(value)) ?? Data())
    }

    private func refuse(_ status: Int, _ code: String, _ message: String? = nil) -> HttpResponse {
        ok(ErrorAnswer(error: code, message: message), status: status)
    }

    private static let noContent = HttpResponse(status: 204)

    private func newId(_ prefix: String) -> String {
        defer { nextId += 1 }
        return "\(prefix)-new-\(nextId)"
    }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if mode == .serverDown { return HttpResponse(status: 502, json: "<html>502 Bad Gateway</html>") }
        let signedIn = request.headers["Cookie"]?.contains("better-auth.session_token=stub-session") == true
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let path = request.url.path

        if path.hasPrefix("/auth/") {
            return auth(request.method, path, body, signedIn: signedIn)
        }
        guard path.hasPrefix("/api/") else { return refuse(404, "not_found") }
        guard signedIn else { return HttpResponse(status: 401, json: #"{"error":"Authentication required"}"#) }
        return api(request, body)
    }

    private func auth(_ method: String, _ path: String, _ body: [String: Any], signedIn: Bool) -> HttpResponse {
        switch (method, path) {
        case ("POST", "/auth/sign-in/email"):
            guard (body["email"] as? String)?.lowercased() == Self.email, body["password"] as? String == Self.password else {
                return HttpResponse(status: 401, json: #"{"code":"INVALID_EMAIL_OR_PASSWORD","message":"Invalid email or password"}"#)
            }
            return HttpResponse(status: 200, json: #"{"redirect":false}"#, setCookies: [Self.cookie])
        case ("POST", "/auth/sign-up/email"):
            if (body["email"] as? String)?.lowercased() == Self.email {
                return HttpResponse(status: 422, json: #"{"code":"USER_ALREADY_EXISTS","message":"User already exists"}"#)
            }
            return HttpResponse(status: 200, json: #"{"token":null}"#, setCookies: [Self.cookie])
        case ("POST", "/auth/request-password-reset"):
            return HttpResponse(status: 200, json: #"{"status":true}"#)
        case ("POST", "/auth/sign-out"):
            return HttpResponse(status: 200, json: #"{"success":true}"#, setCookies: [Self.gone])
        case ("GET", "/auth/get-session"):
            guard signedIn else { return HttpResponse(status: 200, json: "null") }
            return ok(AuthSession(user: user, session: SessionInfo(id: "sess", userId: Self.userId, expiresAt: "2099-01-01T00:00:00.000Z")))
        case ("POST", "/auth/change-password"), ("POST", "/auth/change-email"), ("POST", "/auth/delete-user"):
            guard signedIn else { return HttpResponse(status: 401, json: #"{"code":"UNAUTHORIZED","message":"Unauthorized"}"#) }
            guard body["currentPassword"] as? String ?? body["password"] as? String == Self.password else {
                return HttpResponse(status: 400, json: #"{"code":"INVALID_PASSWORD","message":"Invalid password"}"#)
            }
            if path == "/auth/delete-user" { return HttpResponse(status: 200, json: #"{"success":true}"#, setCookies: [Self.gone]) }
            return HttpResponse(status: 200, json: #"{"status":true}"#)
        case ("POST", "/auth/send-verification-email"):
            return HttpResponse(status: 200, json: #"{"status":true}"#)
        default:
            return refuse(404, "not_found")
        }
    }

    private func api(_ request: HttpRequest, _ body: [String: Any]) -> HttpResponse {
        let parts = request.url.path.split(separator: "/").map(String.init).dropFirst() // after "api"
        let form = MultipartForm.fields(of: request.body ?? Data(), contentType: request.headers["Content-Type"])
        let query = Dictionary(
            (URLComponents(url: request.url, resolvingAgainstBaseURL: true)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        switch (request.method, Array(parts)) {
        case ("GET", ["health"]):
            return ok(HealthResponse(ok: true))
        case ("GET", ["map"]):
            return ok(stickers)

        // Hunting
        case ("POST", ["finds"]):
            guard let id = form["stickerId"], let i = stickers.firstIndex(where: { $0.id == id }) else { return refuse(404, "not_found", "Unknown sticker") }
            let s = stickers[i]
            if s.status == .archived { return refuse(409, "archived") }
            if s.state == .found || s.placedByMe { return refuse(409, "already_found", "Already in your collection") }
            let findId = newId("f")
            stickers[i].state = .found
            stickers[i].foundAt = Self.now
            stickers[i].findPhotoId = "p-\(findId)"
            stickers[i].description = stickers[i].description ?? "Bien caché, bravo !"
            stickers[i].hint = nil
            stickers[i].wishlisted = false
            let f = stickers[i]
            finds.insert(CollectionItem(
                stickerId: f.id, findId: findId, foundAt: Self.now, foundLng: Double(form["lng"] ?? "") ?? f.lng, foundLat: Double(form["lat"] ?? "") ?? f.lat,
                findPhotoId: "p-\(findId)", placeName: f.placeName, hint: nil, description: f.description, placedById: f.placedById,
                placedByName: f.placedByName, placementPhotoId: f.placementPhotoId, countryCode: "CH", placedAt: f.placedAt, status: f.status
            ), at: 0)
            return ok(CreateFindResponse(id: findId, stickerId: f.id, state: .found), status: 201)
        case ("POST", ["reports"]):
            guard let id = form["stickerId"], let s = stickers.first(where: { $0.id == id }) else { return refuse(404, "not_found") }
            if s.placedByMe { return refuse(403, "cannot_report_own") }
            if s.status == .archived { return refuse(409, "archived") }
            if reported.contains(id) { return refuse(409, "already_reported") }
            reported.insert(id)
            return ok(CreatedResponse(id: newId("r")), status: 201)
        case ("POST", ["wishlist"]):
            guard let id = body["stickerId"] as? String, let i = stickers.firstIndex(where: { $0.id == id }) else { return refuse(404, "not_found") }
            stickers[i].wishlisted = true
            return Self.noContent
        case ("DELETE", let p) where p.count == 2 && p[0] == "wishlist":
            if let i = stickers.firstIndex(where: { $0.id == p[1] }) { stickers[i].wishlisted = false }
            return Self.noContent

        // Placing and the own birds
        case ("POST", ["stickers"]):
            if let token = form["clientToken"], let made = tokens[token] { return ok(CreatedResponse(id: made)) }
            guard let lng = Double(form["lng"] ?? ""), let lat = Double(form["lat"] ?? "") else { return refuse(400, "invalid_input") }
            let id = newId("s")
            if let token = form["clientToken"] { tokens[token] = id }
            stickers.append(MapSticker(
                id: id, lng: lng, lat: lat, placeName: form["placeName"] ?? "Rue du Bourg 8, Lausanne", state: .found, status: .active,
                placedByMe: true, placedById: Self.userId, placedByName: userName, hint: form["hint"], description: form["description"],
                placementPhotoId: form["photo"] != nil ? "p-\(id)" : nil, hasOpenReport: false, hasFinds: false, wishlisted: false,
                isPrivate: form["isPrivate"] != nil, placedAt: Self.now
            ))
            return ok(CreatedResponse(id: id), status: 201)
        case ("GET", ["stickers", "me"]):
            return ok(stickers.filter(\.placedByMe).reversed().map { s in
                MyPlacedSticker(
                    id: s.id, lng: s.lng, lat: s.lat, placeName: s.placeName, hint: s.hint, description: s.description,
                    placementPhotoId: s.placementPhotoId, discoveryRadiusM: s.discoveryRadiusM, placedAt: s.placedAt, countryCode: "CH",
                    status: s.status, isPrivate: s.isPrivate, findCount: finders[s.id]?.count ?? 0, reportCount: reports[s.id]?.count ?? 0,
                    hasOpenReport: reports[s.id]?.contains { $0.status == .open } ?? false
                )
            })
        case ("GET", let p) where p.count == 3 && p[0] == "stickers" && (p[2] == "finders" || p[2] == "reports"):
            guard let s = stickers.first(where: { $0.id == p[1] }) else { return refuse(404, "not_found") }
            guard s.placedByMe else { return refuse(403, "forbidden") }
            return p[2] == "finders" ? ok(finders[s.id] ?? []) : ok(reports[s.id] ?? [])
        case ("PATCH", let p) where p.count == 2 && p[0] == "stickers":
            guard let i = stickers.firstIndex(where: { $0.id == p[1] }) else { return refuse(404, "not_found") }
            guard stickers[i].placedByMe else { return refuse(403, "forbidden") }
            let patch = (request.body.flatMap { try? ApiJson.decoder.decode(JsonObject.self, from: $0) }) ?? [:]
            stickers[i] = stickers[i].applyPatch(patch)
            if patch["status"]?.stringValue == "archived" { settleReports(p[1], .resolved) }
            return Self.noContent
        case ("DELETE", let p) where p.count == 2 && p[0] == "stickers":
            guard let s = stickers.first(where: { $0.id == p[1] }) else { return refuse(404, "not_found") }
            guard s.placedByMe else { return refuse(403, "forbidden") }
            stickers.removeAll { $0.id == s.id }
            finds.removeAll { $0.stickerId == s.id }
            return Self.noContent
        case ("PATCH", let p) where p.count == 2 && p[0] == "reports":
            guard let sid = reports.first(where: { $0.value.contains { $0.id == p[1] } })?.key else { return refuse(404, "not_found") }
            let accepted = body["status"] as? String == "accepted"
            settleReports(sid, accepted ? .accepted : .resolved)
            if accepted, let i = stickers.firstIndex(where: { $0.id == sid }) { stickers[i].status = .archived }
            return Self.noContent
        case ("GET", ["geocode", "reverse"]):
            return ok(ReverseGeocodeResponse(address: "Place Saint-François 15, Lausanne"))
        case ("GET", ["collection"]):
            return ok(finds)
        case ("GET", let p) where p.count == 2 && p[0] == "photos":
            return refuse(404, "not_found")

        // The player
        case ("GET", ["profile"]):
            return ok(PublicUser(id: Self.userId, email: Self.email, displayName: userName, isAdmin: false))
        case ("POST", ["profile"]):
            if let name = form["name"], !name.isEmpty { userName = name }
            return ok(PublicUser(id: Self.userId, email: Self.email, displayName: userName, isAdmin: false))
        case ("GET", ["me", "prefs"]):
            return ok(prefs)
        case ("PATCH", ["me", "prefs"]):
            prefs = prefs.merge(request.body.flatMap { try? ApiJson.decoder.decode(JsonObject.self, from: $0) })
            return Self.noContent
        case ("GET", ["me", "export"]):
            return HttpResponse(status: 200, body: Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)))
        case ("PUT", ["me", "push-tokens"]):
            return Self.noContent
        case ("DELETE", let p) where p.count == 3 && p[0] == "me" && p[1] == "push-tokens":
            return Self.noContent
        case ("GET", let p) where p.count == 2 && p[0] == "users":
            return profile(p[1]).map { ok($0) } ?? refuse(404, "not_found")
        case ("GET", ["leaderboard"]):
            return ok(leaderboard(abroad: query["scope"] == "abroad"))

        // Sticker orders
        case ("GET", ["sticker-requests", "mine"]):
            guard let pending = requests.first(where: { $0.status == .pending }) else { return HttpResponse(status: 200, json: "null") }
            return ok(pending)
        case ("GET", ["sticker-requests", "history"]):
            let offset = Int(query["offset"] ?? "") ?? 0
            let done = requests.filter { $0.status != .pending }.sorted { $0.createdAt > $1.createdAt }
            return ok(StickerRequestHistoryResponse(total: done.count, requests: Array(done.dropFirst(offset).prefix(20))))
        case ("POST", ["sticker-requests"]):
            if requests.contains(where: { $0.status == .pending }) { return refuse(409, "already_pending", "Tu as déjà une commande en cours") }
            guard let quantity = body["quantity"] as? Int, let mode = (body["deliveryMode"] as? String).flatMap(DeliveryMode.init(rawValue:)) else {
                return refuse(400, "invalid_input")
            }
            let r = StickerRequest(
                id: newId("o"), deliveryMode: mode, quantity: quantity, address: body["address"] as? String,
                message: body["message"] as? String, status: .pending, createdAt: Self.now
            )
            requests.append(r)
            return ok(r, status: 201)
        case ("POST", let p) where p.count == 3 && p[0] == "sticker-requests" && p[2] == "cancel":
            guard let i = requests.firstIndex(where: { $0.id == p[1] }) else { return refuse(404, "not_found") }
            guard requests[i].status == .pending else { return refuse(409, "not_pending") }
            requests[i].status = .cancelled
            requests[i].handledAt = Self.now
            return ok(requests[i])
        default:
            return refuse(404, "not_found")
        }
    }

    private func settleReports(_ stickerId: String, _ status: ReportStatus) {
        reports[stickerId] = reports[stickerId]?.map { r in
            var r = r
            if r.status == .open { r.status = status }
            return r
        }
        if let i = stickers.firstIndex(where: { $0.id == stickerId }) { stickers[i].hasOpenReport = false }
    }

    private func profile(_ id: String) -> PublicProfile? {
        switch id {
        case Self.userId:
            return PublicProfile(id: id, displayName: userName, placedCount: stickers.filter(\.placedByMe).count, foundCount: finds.count)
        default:
            let placed = stickers.filter { $0.placedById == id }
            guard let name = placed.first?.placedByName ?? Self.players[id] else { return nil }
            return PublicProfile(id: id, displayName: name, placedCount: max(placed.count, 3), foundCount: 14)
        }
    }

    private static let players = ["u-alice": "alice", "u-bob": "bob", "u-chloe": "chloé", "u-david": "david"]

    private func leaderboard(abroad: Bool) -> LeaderboardResponse {
        let me = LeaderboardEntry(userId: Self.userId, displayName: userName, count: finds.count)
        let finders = [
            LeaderboardEntry(userId: "u-chloe", displayName: "chloé", count: abroad ? 4 : 27),
            LeaderboardEntry(userId: "u-bob", displayName: "bob", count: abroad ? 2 : 19),
            LeaderboardEntry(userId: "u-david", displayName: "david", count: abroad ? 1 : 8),
            me,
        ].sorted { $0.count > $1.count }
        let placers = [
            LeaderboardEntry(userId: "u-alice", displayName: "alice", count: abroad ? 3 : 22),
            LeaderboardEntry(userId: "u-bob", displayName: "bob", count: abroad ? 0 : 11),
            LeaderboardEntry(userId: Self.userId, displayName: userName, count: stickers.filter(\.placedByMe).count),
        ].filter { $0.count > 0 }.sorted { $0.count > $1.count }
        return LeaderboardResponse(placers: placers, finders: finders.filter { $0.count > 0 })
    }
}

private struct ErrorAnswer: Encodable {
    var error: String
    var message: String?
}
