import Foundation

/// Drives the offline queue (Android: sync/OfflineSync.kt; web: OfflineSyncManager).
/// The app drains it when it comes to the foreground and when the network comes
/// back; [schedule] asks the system to try again later (a BGTask on iOS — Android's
/// WorkManager job). A drain that landed something says so on [onLanded], for the map.
@MainActor
public final class OfflineSync {
    private let queue: OfflineQueue
    private let sender: any QueueSender
    private let userId: () -> String?
    private let schedule: () -> Void

    /// After a drain that landed or failed something: what was shown before it was
    /// sent must be refetched (to undo it, for a refusal). The count is the landed ones.
    public var onLanded: ((Int) -> Void)?

    /// [userId]: the signed-in account, or the last one when woken in the background.
    public init(queue: OfflineQueue, sender: any QueueSender, userId: @escaping () -> String?, schedule: @escaping () -> Void) {
        self.queue = queue
        self.sender = sender
        self.userId = userId
        self.schedule = schedule
    }

    /// Send what is pending now; nil when nobody is signed in.
    @discardableResult
    public func drain() async -> DrainResult? {
        guard let user = userId() else { return nil }
        let r = await queue.drain(userId: user, sender: sender)
        if r.landed > 0 || r.failed > 0 { onLanded?(r.landed) }
        if r.stillPending { schedule() }
        return r
    }

    /// After parking an action, and at launch when something waits: let the system watch the network.
    public func scheduleIfPending() {
        if queue.items.contains(where: { $0.status == .pending }) { schedule() }
    }
}
