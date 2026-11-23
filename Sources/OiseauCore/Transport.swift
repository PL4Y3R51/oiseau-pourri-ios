import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange, without cookies: [SessionCookieJar] adds and keeps them,
/// so the session behaves the same on every OS and in tests.
public struct HttpRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// The path and query, as a test or the stub server reads it.
    public var pathAndQuery: String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let path = comps?.percentEncodedPath ?? url.path
        return comps?.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }
}

public struct HttpResponse: Sendable {
    public var status: Int
    /// Every `Set-Cookie` header, one cookie each.
    public var setCookies: [String]
    public var body: Data

    public init(status: Int, setCookies: [String] = [], body: Data = Data()) {
        self.status = status
        self.setCookies = setCookies
        self.body = body
    }

    public init(status: Int, json: String, setCookies: [String] = []) {
        self.init(status: status, setCookies: setCookies, body: Data(json.utf8))
    }
}

/// No answer at all: no route, refused, reset, timed out.
public struct TransportFailure: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Where requests go: the network in the app, a script in tests, a stub server in screenshots.
public protocol Transport: Sendable {
    func send(_ request: HttpRequest) async throws -> HttpResponse
}

/// The real network. URLSession's own cookie handling is off: the jar does it.
public final class URLSessionTransport: Transport {
    private let session: URLSession

    /// [readTimeout]: how long a silent server is waited for (Android: 20 s read timeout).
    public init(readTimeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = readTimeout
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.httpBody = request.body
        for (name, value) in request.headers { req.setValue(value, forHTTPHeaderField: name) }
        let session = self.session
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: req) { data, response, error in
                guard let http = response as? HTTPURLResponse, error == nil else {
                    continuation.resume(throwing: TransportFailure(error.map { "\($0)" } ?? "no response"))
                    return
                }
                let cookies = http.value(forHTTPHeaderField: "Set-Cookie").map(splitSetCookieHeader) ?? []
                continuation.resume(returning: HttpResponse(status: http.statusCode, setCookies: cookies, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

/// URLSession folds repeated `Set-Cookie` headers into one, comma-joined. Split it
/// back on the commas that start a new `name=` — not the one inside an `Expires` date.
public func splitSetCookieHeader(_ header: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var index = header.startIndex
    while index < header.endIndex {
        let ch = header[index]
        if ch == "," {
            let rest = header[header.index(after: index)...]
            if startsANewCookie(rest) {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = header.index(after: index)
                continue
            }
        }
        current.append(ch)
        index = header.index(after: index)
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { parts.append(last) }
    return parts
}

private func startsANewCookie(_ rest: Substring) -> Bool {
    let trimmed = rest.drop(while: { $0 == " " })
    guard let eq = trimmed.firstIndex(of: "=") else { return false }
    let name = trimmed[..<eq]
    return !name.isEmpty && !name.contains(where: { $0 == ";" || $0 == "," || $0 == " " })
}

/// Runs [operation], or fails with a [TransportFailure] once [seconds] have passed.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TransportFailure("timed out after \(seconds) s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
