import Foundation

// The Collection tab's client rules (Android: domain/Collection.kt; web:
// CollectionPage.tsx, CollectionControls.tsx): sort, filter and group over the two
// loaded lists, no network.

/// « Trouvés » (birds you found) or « Cachés » (birds you placed). Remembered per device.
public enum CollectionTab: String, Sendable, CaseIterable { case found, hidden }

public enum SortKey: String, Sendable, CaseIterable {
    case date, alpha
    /// « Cachés » only: how often your bird was found.
    case finds

    public var labelKey: String {
        switch self {
        case .date: return "collection_sort_date"
        case .alpha: return "collection_sort_alpha"
        case .finds: return "collection_sort_finds"
        }
    }

    /// The direction's label when descending / ascending.
    public var descKey: String {
        switch self {
        case .date: return "collection_dir_recent"
        case .alpha: return "collection_dir_z_a"
        case .finds: return "collection_dir_most_found"
        }
    }

    public var ascKey: String {
        switch self {
        case .date: return "collection_dir_oldest"
        case .alpha: return "collection_dir_a_z"
        case .finds: return "collection_dir_least_found"
        }
    }
}

public struct CollectionSort: Hashable, Sendable {
    public var key: SortKey
    public var descending: Bool

    public init(_ key: SortKey = .date, descending: Bool = true) {
        self.key = key
        self.descending = descending
    }

    public var isDefault: Bool { self == CollectionSort() }
}

public enum Grouping: String, Sendable, CaseIterable {
    case none, country, month

    public var labelKey: String { "collection_group_\(rawValue)" }
}

/// The country code of a bird whose country is unknown, in filters and groups.
public let unknownCountry = "??"

public struct CollectionFilters: Hashable, Sendable {
    /// Lifecycle statuses to keep (empty = all). « Cachés » only.
    public var statuses: Set<StickerStatus>
    /// « Cachés » only: just the birds with an open missing-report.
    public var reportedOnly: Bool
    /// Country codes to keep (empty = all); [unknownCountry] for none.
    public var countries: Set<String>

    public init(statuses: Set<StickerStatus> = [], reportedOnly: Bool = false, countries: Set<String> = []) {
        self.statuses = statuses
        self.reportedOnly = reportedOnly
        self.countries = countries
    }

    public var active: Bool { !statuses.isEmpty || reportedOnly || !countries.isEmpty }
}

public func sortKeysFor(_ tab: CollectionTab) -> [SortKey] {
    tab == .hidden ? SortKey.allCases : [.date, .alpha]
}

/// web: changeTab — « Trouvailles » only sorts placed birds; the found tab falls back on the date.
public func sortForTab(_ sort: CollectionSort, _ tab: CollectionTab) -> CollectionSort {
    tab == .found && sort.key == .finds ? CollectionSort(.date, descending: sort.descending) : sort
}

/// web: localeCompare — case ignored, accents second (« Écluse » next to « Eglise »).
/// Folded first, then accents break ties: the same everywhere, ICU or not.
func placeOrder(_ a: String, _ b: String, locale: Locale = .current) -> ComparisonResult {
    let fa = a.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    let fb = b.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    if fa != fb { return fa < fb ? .orderedAscending : .orderedDescending }
    let ca = a.folding(options: [.caseInsensitive], locale: locale)
    let cb = b.folding(options: [.caseInsensitive], locale: locale)
    if ca == cb { return .orderedSame }
    return ca < cb ? .orderedAscending : .orderedDescending
}

private extension MyPlacedSticker { var country: String { countryCode ?? unknownCountry } }
private extension CollectionItem { var country: String { countryCode ?? unknownCountry } }

/// Stable sort by [ascending], reversed when descending (Kotlin's sortedWith + reversed()).
private func sorted<T>(_ items: [T], descending: Bool, _ ascending: (T, T) -> ComparisonResult) -> [T] {
    let indexed = items.enumerated().map { ($0.offset, $0.element) }
    return indexed.sorted { l, r in
        var c = ascending(l.1, r.1)
        if descending { c = c == .orderedAscending ? .orderedDescending : c == .orderedDescending ? .orderedAscending : .orderedSame }
        return c == .orderedSame ? l.0 < r.0 : c == .orderedAscending
    }.map(\.1)
}

private func compare<V: Comparable>(_ a: V, _ b: V) -> ComparisonResult {
    a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
}

public func visibleHidden(_ all: [MyPlacedSticker], _ f: CollectionFilters, _ sort: CollectionSort) -> [MyPlacedSticker] {
    let kept = all.filter { s in
        (f.statuses.isEmpty || f.statuses.contains(s.status)) &&
            (!f.reportedOnly || s.hasOpenReport) &&
            (f.countries.isEmpty || f.countries.contains(s.country))
    }
    return sorted(kept, descending: sort.descending) { a, b in
        switch sort.key {
        case .alpha: return placeOrder(a.placeName, b.placeName)
        case .finds: return compare(a.findCount, b.findCount)
        case .date: return compare(a.placedAt, b.placedAt)
        }
    }
}

public func visibleFound(_ all: [CollectionItem], _ f: CollectionFilters, _ sort: CollectionSort) -> [CollectionItem] {
    let kept = all.filter { f.countries.isEmpty || f.countries.contains($0.country) }
    return sorted(kept, descending: sort.descending) { a, b in
        sort.key == .alpha ? placeOrder(a.placeName, b.placeName) : compare(a.foundAt, b.foundAt)
    }
}

/// The distinct countries of the tab's birds, for the country filter.
public func countryCodes(_ tab: CollectionTab, found: [CollectionItem], hidden: [MyPlacedSticker]) -> Set<String> {
    tab == .hidden ? Set(hidden.map(\.country)) : Set(found.map(\.country))
}

/// Drop filter choices whose category is gone — a tab switch, the last archived bird
/// reactivated, a country no longer there — so a stale filter can't hide everything
/// (web: CollectionPage's pruning effect).
public func pruneFilters(_ f: CollectionFilters, tab: CollectionTab, hasArchived: Bool, reportedCount: Int, countries: Set<String>) -> CollectionFilters {
    var statuses = f.statuses
    if !(tab == .hidden && hasArchived) { statuses.remove(.archived) }
    return CollectionFilters(
        statuses: statuses,
        reportedOnly: tab == .hidden && reportedCount > 0 && f.reportedOnly,
        countries: f.countries.intersection(countries)
    )
}

/// Which filter sections have something behind them (web: CollectionControls).
public struct FilterAvailability: Hashable, Sendable {
    public var status: Bool
    public var reported: Bool
    public var countries: Bool

    public init(status: Bool, reported: Bool, countries: Bool) {
        self.status = status
        self.reported = reported
        self.countries = countries
    }

    public var any: Bool { status || reported || countries }
}

public func filterAvailability(_ tab: CollectionTab, hasArchived: Bool, reportedCount: Int, countryCount: Int) -> FilterAvailability {
    FilterAvailability(
        status: tab == .hidden && hasArchived,
        reported: tab == .hidden && reportedCount > 0,
        countries: countryCount > 1
    )
}

/// Labelled sections, in the order their first item appears (the list is sorted already).
public struct CollectionSection<T> {
    public var key: String
    public var label: String
    public var items: [T]

    public init(key: String, label: String, items: [T]) {
        self.key = key
        self.label = label
        self.items = items
    }
}

extension CollectionSection: Equatable where T: Equatable {}

public func groupSections<T>(_ items: [T], key keyOf: (T) -> String, label labelOf: (T) -> String) -> [CollectionSection<T>] {
    var order: [String] = []
    var groups: [String: [T]] = [:]
    for item in items {
        let k = keyOf(item)
        if groups[k] == nil { order.append(k) }
        groups[k, default: []].append(item)
    }
    return order.map { k in CollectionSection(key: k, label: labelOf(groups[k]![0]), items: groups[k]!) }
}

/// « septembre 2026 » — the month group's key and label.
public func monthLabel(_ iso: String, locale: Locale, timeZone: TimeZone = .current) -> String {
    guard let date = parseIsoDate(iso) else { return String(iso.prefix(7)) }
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = timeZone
    f.dateFormat = "LLLL yyyy"
    return f.string(from: date)
}

/// « Suisse » for "CH", or nil for an unknown country (worded by the caller).
public func countryName(_ code: String?, locale: Locale) -> String? {
    guard let code, code != unknownCountry, code.count == 2 else { return nil }
    let name = locale.localizedString(forRegionCode: code.uppercased())
    guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty, name.uppercased() != code.uppercased() else { return nil }
    return name
}

/// The API's timestamps (`2026-09-20T10:00:00Z`, with or without milliseconds).
public func parseIsoDate(_ iso: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)
}

/// The header's chips: only what the tab toggle doesn't already say, and never a zero.
public struct CollectionStats: Hashable, Sendable {
    public var finds: Int
    public var countries: Int

    public init(finds: Int, countries: Int) {
        self.finds = finds
        self.countries = countries
    }
}

public func collectionStats(_ tab: CollectionTab, found: [CollectionItem], hidden: [MyPlacedSticker]) -> CollectionStats {
    if tab == .hidden {
        return CollectionStats(finds: hidden.reduce(0) { $0 + $1.findCount }, countries: Set(hidden.compactMap(\.countryCode)).count)
    }
    return CollectionStats(finds: 0, countries: Set(found.compactMap(\.countryCode)).count)
}
