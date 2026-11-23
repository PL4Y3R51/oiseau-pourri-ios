import Foundation

// The map as the player left it (issue #89; Android: data/PendingOverlay.kt): the
// server's list with this account's parked changes laid back on top, oldest first —
// so a refetch while they wait doesn't flip a ❤ or a private flag back, or bring a
// deleted bird back, until the drain has sent them.

private func pendingAboutBirds(_ queue: [QueuedAction], _ userId: String?) -> [QueuedAction] {
    guard let userId else { return [] }
    return queue.filter { $0.userId == userId && $0.status == .pending && $0.stickerId != nil }
}

/// A PATCH body's `status`, if it names one.
private func patchedStatus(in p: JsonObject, else current: StickerStatus) -> StickerStatus {
    switch p["status"]?.stringValue {
    case "archived": return .archived
    case "active": return .active
    default: return current
    }
}

/// A text field of a PATCH body: absent keeps [current], a JSON null clears it.
private func text(_ p: JsonObject, _ key: String, _ current: String?) -> String? {
    guard let v = p[key] else { return current }
    if v.isNull { return nil }
    return v.stringValue ?? current
}

public extension Array where Element == MapSticker {
    func withPending(_ queue: [QueuedAction], userId: String?) -> [MapSticker] {
        let mine = pendingAboutBirds(queue, userId)
        if mine.isEmpty { return self }
        let deleted = Set(mine.filter { $0.kind == .stickerDelete }.compactMap(\.stickerId))
        return filter { !deleted.contains($0.id) }.map { s in
            mine.filter { $0.stickerId == s.id }.reduce(s) { acc, rec in acc.applying(rec) }
        }
    }
}

public extension Array where Element == MyPlacedSticker {
    /// Same, for the Collection's « Cachés » (my placed birds).
    func withPendingPlaced(_ queue: [QueuedAction], userId: String?) -> [MyPlacedSticker] {
        let mine = pendingAboutBirds(queue, userId)
        if mine.isEmpty { return self }
        let deleted = Set(mine.filter { $0.kind == .stickerDelete }.compactMap(\.stickerId))
        return filter { !deleted.contains($0.id) }.map { s in
            mine.filter { $0.stickerId == s.id && ($0.kind == .stickerToggle || $0.kind == .stickerEdit) }
                .reduce(s) { acc, rec in
                    guard let p = rec.payload else { return acc }
                    var out = acc
                    out.isPrivate = p["isPrivate"]?.boolValue ?? acc.isPrivate
                    out.status = patchedStatus(in: p, else: acc.status)
                    out.placeName = p["placeName"]?.stringValue ?? acc.placeName
                    out.hint = text(p, "hint", acc.hint)
                    out.description = text(p, "description", acc.description)
                    return out
                }
        }
    }
}

public extension MapSticker {
    fileprivate func applying(_ rec: QueuedAction) -> MapSticker {
        switch rec.kind {
        case .wishlist:
            guard let on = rec.wishlistOn else { return self }
            var copy = self
            copy.wishlisted = on
            return copy
        case .stickerToggle, .stickerEdit:
            return applyPatch(rec.payload)
        default:
            return self
        }
    }

    /// A sticker PATCH body (UpdateStickerBody's fields) on a map pin. A JSON null clears a text.
    func applyPatch(_ p: JsonObject?) -> MapSticker {
        guard let p else { return self }
        var out = self
        out.isPrivate = p["isPrivate"]?.boolValue ?? isPrivate
        out.status = patchedStatus(in: p, else: status)
        out.placeName = text(p, "placeName", placeName) ?? placeName
        out.hint = text(p, "hint", hint)
        out.description = text(p, "description", description)
        out.lng = p["lng"]?.doubleValue ?? lng
        out.lat = p["lat"]?.doubleValue ?? lat
        return out
    }
}
