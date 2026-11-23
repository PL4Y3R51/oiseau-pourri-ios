import Foundation

// The map's client-side rules (Android: domain/MapRules.kt, ui/map/PinSprites.kt;
// web: stickerKind.ts, mapFilter.ts). Pure, so they are unit-tested.

/// A pin's state, as computed per user (spec §4.3).
public enum PinKind: String, CaseIterable, Sendable {
    case available, found, mine, archived
}

/// Everything that changes how one pin looks. Each distinct value is one sprite.
public struct PinStyle: Hashable, Sendable {
    public var kind: PinKind
    /// On the player's wishlist: golden halo + star badge.
    public var wish = false
    /// The player's own bird has an open "disappeared" report: red dot.
    public var reported = false
    /// Placed on private property: house badge.
    public var isPrivate = false

    public init(_ kind: PinKind, wish: Bool = false, reported: Bool = false, isPrivate: Bool = false) {
        self.kind = kind
        self.wish = wish
        self.reported = reported
        self.isPrivate = isPrivate
    }

    /// Stable id of the sprite in the map style.
    public var spriteId: String {
        var id = "pin-\(kind.rawValue)"
        if wish { id += "-wish" }
        if reported { id += "-reported" }
        if isPrivate { id += "-private" }
        return id
    }

    /// Every combination: what the map registers once at style load.
    public static let all: [PinStyle] = PinKind.allCases.flatMap { k in
        [false, true].flatMap { w in [false, true].flatMap { r in [false, true].map { p in PinStyle(k, wish: w, reported: r, isPrivate: p) } } }
    }
}

public extension MapSticker {
    /// Archived beats mine, mine beats found, otherwise available.
    var pinKind: PinKind {
        if status == .archived { return .archived }
        if placedByMe { return .mine }
        if state == .found { return .found }
        return .available
    }

    /// `hasOpenReport` is only ever sent for own birds.
    var pinStyle: PinStyle {
        PinStyle(pinKind, wish: wishlisted, reported: hasOpenReport == true, isPrivate: isPrivate)
    }

    /// Found by the player (the server also marks their own birds found).
    var foundByMe: Bool { !placedByMe && state == .found }
}

// MARK: - Filters

/// The filter popover's categories, in the web's order. OR semantics.
public enum MapFilter: String, CaseIterable, Sendable {
    case wishlist, toFind, found, mine, reported

    /// The Localizable.xcstrings key of its label.
    public var labelKey: String {
        switch self {
        case .wishlist: return "map_filter_wishlist"
        case .toFind: return "map_filter_to_find"
        case .found: return "map_filter_found"
        case .mine: return "map_filter_mine"
        case .reported: return "map_filter_reported"
        }
    }

    public func matches(_ s: MapSticker) -> Bool {
        switch self {
        case .wishlist: return s.wishlisted
        case .toFind: return s.state == .available && s.status == .active
        case .found: return s.state == .found && !s.placedByMe
        case .mine: return s.placedByMe
        case .reported: return s.placedByMe && s.hasOpenReport == true
        }
    }
}

/// What the player chose to see. Per device.
public struct MapFilters: Equatable, Sendable {
    public var active: Set<MapFilter> = []
    public var showArchived = false
    public var showPrivate = true

    public init(active: Set<MapFilter> = [], showArchived: Bool = false, showPrivate: Bool = true) {
        self.active = active
        self.showArchived = showArchived
        self.showPrivate = showPrivate
    }

    /// How far from the defaults: the count on the button and the reset.
    public var deviations: Int { active.count + (showArchived ? 1 : 0) + (showPrivate ? 0 : 1) }

    public func toggled(_ f: MapFilter) -> MapFilters {
        var copy = self
        if copy.active.contains(f) { copy.active.remove(f) } else { copy.active.insert(f) }
        return copy
    }

    public func apply(_ stickers: [MapSticker]) -> [MapSticker] {
        var base = showArchived ? stickers : stickers.filter { $0.status != .archived }
        if !showPrivate { base = base.filter { !$0.isPrivate } }
        if active.isEmpty { return base }
        return base.filter { s in active.contains { $0.matches(s) } }
    }
}

/// One row of the filter popover: shown when it has birds or is switched on.
public struct FilterRow: Equatable, Sendable {
    public var filter: MapFilter
    public var count: Int
    public var on: Bool
}

/// Counts are over the FULL list, not the filtered one.
public func filterRows(_ all: [MapSticker], _ filters: MapFilters) -> [FilterRow] {
    MapFilter.allCases
        .map { f in FilterRow(filter: f, count: all.filter(f.matches).count, on: filters.active.contains(f)) }
        .filter { $0.count > 0 || $0.on }
}

// MARK: - Overlapping pins

/// Pins closer than this on screen (points) open the gallery instead of one sheet.
public let overlapPoints: Double = 22

/// The visible birds stacked under a tapped one, the tapped one included, in list order.
public func stackedWith(_ tapped: MapSticker, _ visible: [MapSticker], threshold: Double, project: (MapSticker) -> (x: Double, y: Double)) -> [MapSticker] {
    let p0 = project(tapped)
    return visible.filter {
        let p = project($0)
        return hypot(p.x - p0.x, p.y - p0.y) <= threshold
    }
}

// MARK: - The bird sheet's menu

/// The "⋯" actions, in the web's order.
public enum StickerAction: Sendable {
    case openInCollection, report, wishlist, placerProfile, makePrivate, archive, delete
}

/// Ghost account that inherits deleted users' birds; it has no profile.
public let deletedUserId = "deleted"

public func stickerActions(_ s: MapSticker) -> [StickerAction] {
    var out: [StickerAction] = []
    let active = s.status == .active
    if s.placedByMe || s.foundByMe { out.append(.openInCollection) }
    // Shown even once found: a bird you caught can still go missing later.
    if !s.placedByMe && active { out.append(.report) }
    if !s.placedByMe && !s.foundByMe && active { out.append(.wishlist) }
    if !s.placedByMe && s.placedById != deletedUserId { out.append(.placerProfile) }
    if s.placedByMe { out += [.makePrivate, .archive, .delete] }
    return out
}

/// Text edits stay open for 5 minutes after placement (shared STICKER_EDIT_WINDOW_MS).
public let stickerEditWindow: TimeInterval = 5 * 60

public func isStickerEditable(placedAt: Date, now: Date) -> Bool {
    now.timeIntervalSince(placedAt) < stickerEditWindow
}
