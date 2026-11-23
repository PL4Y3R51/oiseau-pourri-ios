import Foundation
import Testing
@testable import OiseauCore

/// A scripted server (Android tests: OkHttp's MockWebServer): answers in order,
/// remembers what it was asked.
actor ScriptedTransport: Transport {
    enum Step: Sendable {
        case respond(HttpResponse)
        /// Nothing answers: no route, connection refused.
        case fail
        /// Accepts, then stays silent this long before answering.
        case hang(TimeInterval, HttpResponse)
    }

    private var steps: [Step] = []
    private(set) var requests: [HttpRequest] = []
    /// Once closed, every call fails (the server is gone).
    private var closed = false

    func enqueue(_ step: Step) { steps.append(step) }

    func json(_ status: Int, _ body: String, cookies: [String] = []) {
        steps.append(.respond(HttpResponse(status: status, json: body, setCookies: cookies)))
    }

    func close() { closed = true }

    var requestCount: Int { requests.count }

    func takeRequest() -> HttpRequest { requests.removeFirst() }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        requests.append(request)
        if closed || steps.isEmpty { throw TransportFailure("connection refused") }
        switch steps.removeFirst() {
        case .respond(let r):
            return r
        case .fail:
            throw TransportFailure("connection refused")
        case .hang(let seconds, let r):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return r
        }
    }
}

let testBase = URL(string: "http://api.test/")!
let sessionCookie = "better-auth.session_token=abc.sig; Max-Age=2592000; Path=/; HttpOnly"

@MainActor
func client(_ transport: ScriptedTransport, store: MemoryCookieStore = MemoryCookieStore(), networkUp: Bool = false, languages: [String] = ["fr-CH"]) -> ApiClient {
    ApiClient(baseURL: testBase, cookieJar: SessionCookieJar(store: store), transport: transport, networkUp: { networkUp }, languages: { languages })
}

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/contract") else {
        throw TransportFailure("missing fixture contract/\(name): run tools/sync-from-monorepo.mjs")
    }
    return try Data(contentsOf: url)
}

func text(_ data: Data?) -> String { data.map { String(decoding: $0, as: UTF8.self) } ?? "" }

/// Runs [body] and returns the ApiError it threw, or nil.
@MainActor
func apiError(_ body: () async throws -> Void) async -> ApiError? {
    do {
        try await body()
        return nil
    } catch let error as ApiError {
        return error
    } catch {
        Issue.record("not an ApiError: \(error)")
        return nil
    }
}
