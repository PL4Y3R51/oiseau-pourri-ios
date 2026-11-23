import Foundation

/// Can the game talk to its server right now — and if not, whose side is it on.
public enum Reach: Sendable { case online, noNetwork, serverDown }

public func reachOf(network: Bool, serverAnswers: Bool) -> Reach {
    if !network { return .noNetwork }
    if !serverAnswers { return .serverDown }
    return .online
}

/// One state for "the server can't be reached", whatever the cause (issue #89;
/// Android: sync/Reachability.kt): the phone's network (told by the app's
/// NWPathMonitor through [networkChanged]) and what the last API call got back
/// ([serverAnswered], from [ApiClient.onServerAnswered]). The player sees the
/// difference in the wording only; every action waits the same way.
///
/// A failed call while there is no network says nothing about the server, so it is
/// ignored; and a network coming back gives the server the benefit of the doubt —
/// the next call (the app probes at once) settles it.
@MainActor
public final class Reachability {
    private var hasNetwork: Bool
    private var serverAnswers = true

    public private(set) var state: Reach {
        didSet {
            guard state != oldValue else { return }
            onChange?(state)
            if state == .online { bandClosed = false }
        }
    }

    /// The player closed the band to its slim strip: app-wide, so it stays closed
    /// across screens and a trip to the background — until the server is back; the
    /// next outage shows the band in full again.
    public private(set) var bandClosed = false {
        didSet { if bandClosed != oldValue { onBandClosedChange?(bandClosed) } }
    }

    public var onChange: ((Reach) -> Void)?
    public var onBandClosedChange: ((Bool) -> Void)?

    public init(networkUp: Bool = true) {
        hasNetwork = networkUp
        state = reachOf(network: networkUp, serverAnswers: true)
    }

    public var isOnline: Bool { state == .online }

    /// The network signal, as it changes.
    public func networkChanged(_ up: Bool) {
        if up && !hasNetwork { serverAnswers = true }
        hasNetwork = up
        update()
    }

    public func serverAnswered(_ answered: Bool) {
        if !answered && !hasNetwork { return }
        serverAnswers = answered
        update()
    }

    public func closeBand(_ closed: Bool) {
        bandClosed = closed
    }

    private func update() {
        state = reachOf(network: hasNetwork, serverAnswers: serverAnswers)
    }
}
