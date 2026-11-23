import Foundation

// The birds a player placed, as shown on their profile (spec §4.5; Android:
// domain/ProfileBirds.kt; web: profileBirds.ts). Read from the map list the app
// already holds: it carries every bird with its placer and the disclosure rules
// applied server-side, so the profile needs no API of its own — and shows nothing
// the map doesn't.

/// This player's birds, newest first.
public func birdsPlacedBy(_ stickers: [MapSticker], userId: String) -> [MapSticker] {
    stickers.filter { $0.placedById == userId }.sorted { $0.placedAt > $1.placedAt }
}

/// In colour once the bird is in my collection (or mine); in black and white before.
public enum BirdTone: Sendable { case color, grey }

/// Which picture a profile card shows, and how. [photoId] nil: the mascot
/// placeholder. [blurred]: still a spoiler, blurred on top of the grey, as on the map (spec §4.4).
public struct BirdThumb: Hashable, Sendable {
    public var photoId: String?
    public var tone: BirdTone
    public var blurred: Bool

    public init(photoId: String?, tone: BirdTone, blurred: Bool) {
        self.photoId = photoId
        self.tone = tone
        self.blurred = blurred
    }
}

public extension MapSticker {
    /// True once the bird is in my collection, or is mine: its pictures are no spoiler any more.
    var seenByMe: Bool { placedByMe || state == .found }
}

/// A bird I have found (or placed) is in colour: its placement photo, else my
/// trophy. One I haven't is the placement photo in black and white — and the
/// spoiler rule still holds: blurred until revealed, not shown at all when spoilers are off.
public func birdThumb(_ s: MapSticker, hideSpoilers: Bool, revealed: Bool) -> BirdThumb {
    if s.seenByMe { return BirdThumb(photoId: s.placementPhotoId ?? s.findPhotoId, tone: .color, blurred: false) }
    if s.placementPhotoId == nil || hideSpoilers { return BirdThumb(photoId: nil, tone: .grey, blurred: false) }
    return BirdThumb(photoId: s.placementPhotoId, tone: .grey, blurred: !revealed)
}
