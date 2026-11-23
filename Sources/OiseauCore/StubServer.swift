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
/// seed's: alice@example.com / password123.
public actor StubServer: Transport {
    public enum Mode: Sendable {
        case normal
        /// Every call answers 502, like nginx in front of a dead API.
        case serverDown
    }

    public static let email = "alice@example.com"
    public static let password = "password123"

    private let mode: Mode
    private let latency: TimeInterval
    private var stickers: [MapSticker]

    public init(mode: Mode = .normal, latency: TimeInterval = 0.2, stickers: [MapSticker] = SampleStickers.all) {
        self.mode = mode
        self.latency = latency
        self.stickers = stickers
    }

    private static let user = AuthUser(id: "u-me", email: email, name: "alice", emailVerified: true)
    private static let cookie = "better-auth.session_token=stub-session.sig; Max-Age=2592000; Path=/; HttpOnly; SameSite=Lax"
    private static let gone = "better-auth.session_token=; Max-Age=0; Path=/"

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if mode == .serverDown { return HttpResponse(status: 502, json: "<html>502 Bad Gateway</html>") }
        let signedIn = request.headers["Cookie"]?.contains("better-auth.session_token=stub-session") == true
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch (request.method, request.url.path) {
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
            let session = AuthSession(user: Self.user, session: SessionInfo(id: "sess", userId: Self.user.id, expiresAt: "2099-01-01T00:00:00.000Z"))
            return HttpResponse(status: 200, setCookies: [], body: (try? ApiJson.encoder.encode(session)) ?? Data())
        case ("GET", "/api/map"):
            guard signedIn else { return HttpResponse(status: 401, json: #"{"error":"Authentication required"}"#) }
            return HttpResponse(status: 200, setCookies: [], body: (try? ApiJson.encoder.encode(stickers)) ?? Data())
        default:
            return HttpResponse(status: 404, json: #"{"error":"not_found"}"#)
        }
    }
}
