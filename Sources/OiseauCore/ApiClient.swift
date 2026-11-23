import Foundation

/// Sent as `Origin` on every call: Better Auth trusts it (the API's NATIVE_APP_ORIGIN),
/// and refuses cookie-carrying `/auth` POSTs without one.
public let nativeAppOrigin = "oiseaupourri://app"

/// The `Accept-Language` value for the player's languages, best first.
public func acceptLanguage(_ tags: [String]) -> String {
    var seen = Set<String>()
    let clean = tags
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != "und" && seen.insert($0).inserted }
        .prefix(5)
    return clean.enumerated()
        .map { i, tag in i == 0 ? tag : "\(tag);q=0.\(10 - i)" }
        .joined(separator: ", ")
}

/// Any JSON answer the caller doesn't read.
public struct Ignored: Decodable, Sendable {
    public init(from decoder: Decoder) throws {}
}

/// An empty JSON object, for POSTs that carry no fields.
public struct EmptyBody: Encodable, Sendable {
    public init() {}
}

public enum ApiJson {
    public static let decoder = JSONDecoder()

    /// Keys sorted so a body is the same bytes every time; nil optionals are left out.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// The API and Better Auth, over one [Transport] and the session's cookies
/// (Android: data/ApiClient.kt).
@MainActor
public final class ApiClient {
    public let baseURL: URL
    public let cookieJar: SessionCookieJar
    private let transport: any Transport
    private let networkUp: () -> Bool
    private let languages: () -> [String]

    /// Told after every call whether the server answered (a refusal is an answer; a 5xx is not).
    public var onServerAnswered: ((Bool) -> Void)?

    /// How long a find, a placement or a report waits before it is kept for later.
    public static let gestureTimeout: TimeInterval = 15

    public init(
        baseURL: URL,
        cookieJar: SessionCookieJar,
        transport: any Transport = URLSessionTransport(),
        networkUp: @escaping () -> Bool = { false },
        languages: @escaping () -> [String] = { Locale.preferredLanguages }
    ) {
        self.baseURL = baseURL
        self.cookieJar = cookieJar
        self.transport = transport
        self.networkUp = networkUp
        self.languages = languages
    }

    public func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    /// The raw call: nil for an empty or `null` body.
    public func send(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil, timeout: TimeInterval? = nil) async throws(ApiError) -> Data? {
        let url = self.url(path)
        var headers = ["Origin": nativeAppOrigin, "Accept": "application/json"]
        let lang = acceptLanguage(languages())
        if !lang.isEmpty { headers["Accept-Language"] = lang }
        if let contentType { headers["Content-Type"] = contentType }
        if let cookie = cookieJar.header(for: url) { headers["Cookie"] = cookie }
        let request = HttpRequest(method: method, url: url, headers: headers, body: body)

        let response: HttpResponse
        do {
            let transport = self.transport
            if let timeout {
                response = try await withTimeout(timeout) { try await transport.send(request) }
            } else {
                response = try await transport.send(request)
            }
        } catch {
            onServerAnswered?(false)
            throw ApiError(status: 0, code: ApiError.network, message: "\(error)", unavailable: networkUp() ? .serverDown : .noNetwork)
        }
        onServerAnswered?(response.status < 500)
        cookieJar.save(response.setCookies, from: url)
        guard (200..<300).contains(response.status) else { throw ApiError.from(status: response.status, body: response.body) }
        let text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "null" ? nil : response.body
    }

    private func decode<T: Decodable>(_ data: Data?, _ type: T.Type) throws(ApiError) -> T? {
        guard let data else { return nil }
        do {
            return try ApiJson.decoder.decode(T.self, from: data)
        } catch {
            throw ApiError(status: 200, code: "bad_response", message: "\(error)")
        }
    }

    private func encode<B: Encodable>(_ body: B) -> Data {
        // Our own Codable types: encoding them cannot fail.
        (try? ApiJson.encoder.encode(body)) ?? Data("{}".utf8)
    }

    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws(ApiError) -> T? {
        try decode(await send("GET", path), type)
    }

    public func post<B: Encodable, T: Decodable>(_ path: String, _ body: B, as type: T.Type = T.self, timeout: TimeInterval? = nil) async throws(ApiError) -> T? {
        try decode(await send("POST", path, body: encode(body), contentType: "application/json", timeout: timeout), type)
    }

    public func put<B: Encodable, T: Decodable>(_ path: String, _ body: B, as type: T.Type = T.self) async throws(ApiError) -> T? {
        try decode(await send("PUT", path, body: encode(body), contentType: "application/json"), type)
    }

    public func patch<B: Encodable, T: Decodable>(_ path: String, _ body: B, as type: T.Type = T.self) async throws(ApiError) -> T? {
        try decode(await send("PATCH", path, body: encode(body), contentType: "application/json"), type)
    }

    public func delete<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws(ApiError) -> T? {
        try decode(await send("DELETE", path), type)
    }

    /// A stored photo (`/api/photos/:id`, WebP), sent with the session cookie.
    public func photo(_ id: String, thumb: Bool = false) async throws(ApiError) -> Data? {
        try await send("GET", "/api/photos/\(id)" + (thumb ? "?variant=thumb" : ""))
    }
}
