import Foundation
import Testing
@testable import OiseauCore

/// A server that answers by route (Android tests: MockWebServer's Dispatcher), and
/// writes down every request as `METHOD /path?query body` (the body when it is JSON).
actor RoutedTransport: Transport {
    typealias Route = @Sendable (HttpRequest) -> HttpResponse

    private let route: Route
    private(set) var seen: [String] = []
    private var closed = false

    init(_ route: @escaping Route) { self.route = route }

    func close() { closed = true }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        if closed { throw TransportFailure("connection refused") }
        let isJson = request.headers["Content-Type"]?.hasPrefix("application/json") == true
        let body = isJson ? " " + text(request.body) : ""
        seen.append("\(request.method) \(request.pathAndQuery)\(body)")
        return route(request)
    }
}

func jsonAnswer(_ body: String, status: Int = 200) -> HttpResponse { HttpResponse(status: status, json: body) }

/// A fresh, empty directory under the system's temporary one.
func tempDir(_ name: String = "t") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oiseau-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The multipart parts of a recorded request, by field name (files: their filename).
/// Written apart from MultipartForm on purpose: it checks what went on the wire.
func parts(_ req: HttpRequest) -> [String: String] {
    guard let type = req.headers["Content-Type"], let r = type.range(of: "boundary=") else { return [:] }
    let boundary = String(type[r.upperBound...])
    var out: [String: String] = [:]
    for part in text(req.body).components(separatedBy: "--\(boundary)") {
        guard let n = part.range(of: "name=\"") else { continue }
        let name = String(part[n.upperBound...].prefix { $0 != "\"" })
        if let f = part.range(of: "filename=\"") {
            out[name] = String(part[f.upperBound...].prefix { $0 != "\"" })
        } else if let start = part.range(of: "\r\n\r\n") {
            out[name] = String(part[start.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n-"))
        }
    }
    return out
}

/// `METHOD /path body` of a recorded request.
func sent(_ req: HttpRequest) -> String {
    "\(req.method) \(req.url.path) \(text(req.body))".trimmingCharacters(in: .whitespaces)
}

/// A mutable clock for code that takes `() -> Date`.
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_790_000_000)) { self.now = now }
    func callAsFunction() -> Date { now }
    func advance(_ seconds: TimeInterval) { now += seconds }
}

let here = Position(GeoPoint(lng: 6.6323, lat: 46.5197), accuracyM: 8)
let photoBytes = Data([1, 2, 3])
