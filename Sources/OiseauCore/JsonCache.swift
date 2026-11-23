import Foundation

/// What a read screen shows: the server's answer, or — [staleSince] set — the last one kept.
public struct Fetched<T> {
    public var value: T
    public var staleSince: Date?

    public init(_ value: T, staleSince: Date? = nil) {
        self.value = value
        self.staleSince = staleSince
    }
}

extension Fetched: Equatable where T: Equatable {}
extension Fetched: Sendable where T: Sendable {}

private struct CacheEntry<T: Codable>: Codable {
    /// Epoch ms.
    var fetchedAt: Int64
    var value: T
}

/// The last answer of each read screen — Collection, Classement, Profil, orders —
/// on disk per account (issue #89; Android: data/JsonCache.kt), so without a network
/// or a server they show what they last showed, dated, instead of a bare error.
/// Keep [root] out of backups; gone on sign-out ([clear]).
@MainActor
public final class JsonCache {
    private let root: URL?
    private let userId: () -> String?
    private let clock: () -> Date

    public init(root: URL?, userId: @escaping () -> String?, clock: @escaping () -> Date = Date.init) {
        self.root = root
        self.userId = userId
        self.clock = clock
    }

    /// [call] the server; keep what it answers under [key]. With no usable answer (no
    /// network, 5xx, timeout) the last kept answer, marked stale; a refusal, or nothing
    /// kept, still throws.
    public func fetch<T: Codable>(_ key: String, _ call: () async throws(ApiError) -> T) async throws(ApiError) -> Fetched<T> {
        do {
            let value = try await call()
            put(key, value)
            return Fetched(value)
        } catch {
            guard error.isUnavailable, let kept = get(key, as: T.self) else { throw error }
            return kept
        }
    }

    public func get<T: Codable>(_ key: String, as type: T.Type = T.self) -> Fetched<T>? {
        guard let url = file(key), let data = try? Data(contentsOf: url),
              let entry = try? ApiJson.decoder.decode(CacheEntry<T>.self, from: data) else { return nil }
        return Fetched(entry.value, staleSince: dateOf(epochMs: entry.fetchedAt))
    }

    public func put<T: Codable>(_ key: String, _ value: T) {
        guard let url = file(key), let data = try? ApiJson.encoder.encode(CacheEntry(fetchedAt: epochMs(clock()), value: value)) else { return }
        _ = writeAtomically(data, to: url)
    }

    /// Sign-out: someone else may sign in next.
    public func clear() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func file(_ key: String) -> URL? {
        guard let user = userId(), let root else { return nil }
        // Keys are ours (screen + query); keep them to safe file names anyway.
        return root.appendingPathComponent(Self.safe(user), isDirectory: true).appendingPathComponent(Self.safe(key) + ".json")
    }

    private static func safe(_ s: String) -> String {
        String(s.unicodeScalars.map { c in
            let ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "_" || c == "-"
            return ok ? Character(c) : "_"
        })
    }
}
