import Foundation

/// Any JSON value (Android: kotlinx.serialization's JsonElement). The body of a
/// parked change, a sticker PATCH that must say `"hint": null` (which the
/// generated bodies, nil fields left out, can't), a prefs PATCH being merged.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var isNull: Bool { self == .null }
}

extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// A JSON object: a PATCH body, a parked change's payload.
public typealias JsonObject = [String: JSONValue]

public extension Dictionary where Key == String, Value == JSONValue {
    /// The canonical bytes (keys sorted), as sent.
    func jsonData() -> Data { (try? ApiJson.encoder.encode(self)) ?? Data("{}".utf8) }

    func jsonString() -> String { String(decoding: jsonData(), as: UTF8.self) }

    /// Read as one of our Codable bodies; nil when it doesn't fit.
    func decoded<T: Decodable>(as type: T.Type) -> T? { try? ApiJson.decoder.decode(T.self, from: jsonData()) }

    /// One of our Codable bodies as a JSON object (nil fields left out).
    static func of<T: Encodable>(_ value: T) -> JsonObject {
        guard let data = try? ApiJson.encoder.encode(value) else { return [:] }
        return (try? ApiJson.decoder.decode(JsonObject.self, from: data)) ?? [:]
    }
}

/// Epoch milliseconds, the API's time unit (`capturedAt`).
public func epochMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

public func dateOf(epochMs ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// One caller at a time across `await`s (Android: kotlinx Mutex). MainActor-bound:
/// everything that uses it is.
@MainActor
final class AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T, E: Error>(_ body: () async throws(E) -> T) async throws(E) -> T {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
        defer {
            if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// Writes [data] next to [url] then renames it over: a crash mid-write never leaves half a file.
func writeAtomically(_ data: Data, to url: URL) -> Bool {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        return false
    }
}
