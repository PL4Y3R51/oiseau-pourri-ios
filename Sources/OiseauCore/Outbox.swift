import Foundation

/// How a player change went: the server took it, or it waits on the device.
public enum Sent: Equatable, Sendable {
    case now
    /// Parked: no network ([Unavailable.noNetwork]) or no server ([Unavailable.serverDown]).
    case later(Unavailable)
}

/// The way every player change other than a find or a placement goes out (issue #89;
/// Android: sync/Outbox.kt): the caller has already shown it; this sends it now, or
/// parks it in the [OfflineQueue] when there is no usable answer — no network, a
/// 5xx, a timeout — and lets the drain send it later. A refusal (4xx) still throws:
/// the caller reverts and says so.
///
/// Order matters for the same bird (an offline ❤ then an online un-❤ must not reach
/// the server the other way round): while something about it is parked, a new
/// change is parked behind it and the drain is nudged.
@MainActor
public final class Outbox {
    private let queue: OfflineQueue
    private let userId: () -> String?
    private let knownOffline: () -> Bool
    private let schedule: () -> Void
    private let drainNow: () async -> Void

    /// [schedule]: let the system send what is parked once there is a network (the app's
    /// BGTask / NWPathMonitor). [drainNow]: send what is parked now.
    public init(queue: OfflineQueue, userId: @escaping () -> String?, knownOffline: @escaping () -> Bool, schedule: @escaping () -> Void, drainNow: @escaping () async -> Void) {
        self.queue = queue
        self.userId = userId
        self.knownOffline = knownOffline
        self.schedule = schedule
        self.drainNow = drainNow
    }

    public func change(_ kind: QueuedKind, stickerId: String?, payload: JsonObject, placeName: String = "", send: () async throws(ApiError) -> Void) async throws(ApiError) -> Sent {
        guard let user = userId() else {
            try await send()
            return .now
        }
        if knownOffline() {
            if let later = park(user, kind, stickerId, payload, placeName, .noNetwork) { return later }
            try await send()
            return .now
        }
        if queue.hasPending(userId: user, stickerId: stickerId, kind: stickerId == nil ? kind : nil),
           let later = park(user, kind, stickerId, payload, placeName, .serverDown) {
            await drainNow()
            // Parked behind the others: it went with them, or it waits with them.
            return queue.hasPending(userId: user, stickerId: stickerId) ? later : .now
        }
        do {
            try await send()
            return .now
        } catch {
            guard let why = error.unavailable, let later = park(user, kind, stickerId, payload, placeName, why) else { throw error }
            return later
        }
    }

    private func park(_ user: String, _ kind: QueuedKind, _ stickerId: String?, _ payload: JsonObject, _ placeName: String, _ why: Unavailable) -> Sent? {
        guard queue.queueChange(userId: user, kind: kind, stickerId: stickerId, payload: payload, placeName: placeName) else { return nil }
        schedule()
        return .later(why)
    }
}
