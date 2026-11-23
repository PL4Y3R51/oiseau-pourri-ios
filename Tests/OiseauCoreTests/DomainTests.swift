import Foundation
import Testing
@testable import OiseauCore

private func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}

/// Android: HuntTest.
struct HuntTests {
    @Test func positionStatusLikeTheWeb() {
        #expect(positionStatus(nil) == .of("hunt_locating"))
        #expect(positionStatus(Position(GeoPoint(lng: 0, lat: 0), accuracyM: 11.6)) == .of("hunt_located", "12"))
    }

    @Test func knownRefusalsAreWorded() {
        #expect(findErrorMessage(ApiError(status: 422, code: "too_far", message: "You are not close enough")) == .of("find_error_too_far"))
        #expect(reportErrorMessage(ApiError(status: 409, code: "already_reported")) == .of("report_error_already"))
        #expect(findErrorMessage(ApiError(status: 0, code: ApiError.network, message: "timeout")) == .of("find_error_network"))
        // Unknown codes fall back to the server's message, like the web.
        #expect(findErrorMessage(ApiError(status: 404, code: "not_found", message: "Unknown sticker")) == .raw("Unknown sticker"))
    }
}

/// Android: PlacementTest.
struct PlacementTests {
    private let lausanne = GeoPoint(lng: 6.6323, lat: 46.5197)

    @Test func distanceIsHaversine() {
        // 0.001° of latitude ≈ 111.2 m anywhere.
        #expect(abs(distanceM(lausanne, GeoPoint(lng: lausanne.lng, lat: lausanne.lat + 0.001)) - 111.2) < 0.1)
        #expect(distanceM(lausanne, lausanne) < 1e-9)
    }

    @Test func aPointInsideTheCircleIsLeftAlone() {
        let near = GeoPoint(lng: 6.6330, lat: 46.5200) // ~60 m
        #expect(clampToRadius(lausanne, near, maxM: 100) == near)
    }

    @Test func aPointOutsideIsBroughtBackOnTheEdgeAlongItsBearing() {
        let far = GeoPoint(lng: 6.6423, lat: 46.5297) // ~1.4 km north-east
        let clamped = clampToRadius(lausanne, far, maxM: 100)
        #expect(abs(distanceM(lausanne, clamped) - 100) < 0.01)
        // Same direction: still north-east, and on the segment towards `far`.
        #expect(clamped.lat > lausanne.lat && clamped.lng > lausanne.lng)
        #expect(abs(distanceM(lausanne, far) - (distanceM(lausanne, clamped) + distanceM(clamped, far))) < 0.5)
    }

    @Test func theRadiusRingIsClosedAndRound() {
        let ring = circleRing(lausanne, radiusM: 100)
        #expect(ring.count == 65)
        #expect(abs(ring.first!.lat - ring.last!.lat) < 1e-9)
        #expect(abs(ring.first!.lng - ring.last!.lng) < 1e-9)
        #expect(ring.allSatisfy { abs(distanceM(lausanne, $0) - 100) < 0.01 })
    }

    @Test func adjustmentIsRoundedMetres() {
        #expect(adjustedM(lausanne, lausanne) == 0)
        #expect(adjustedM(lausanne, GeoPoint(lng: lausanne.lng, lat: lausanne.lat + 0.001)) == 111)
    }

    @Test func refusalsAreWorded() {
        #expect(placeErrorMessage(ApiError(status: 400, code: "too_far_from_device", message: "Placement trop loin")) == .of("place_error_too_far"))
        #expect(placeErrorMessage(ApiError(status: 0, code: ApiError.network, message: "timeout")) == .of("place_error_network"))
        #expect(placeErrorMessage(ApiError(status: 400, code: "invalid_input", message: "bad")) == .raw("bad"))
        #expect(editErrorMessage(ApiError(status: 403, code: "edit_window_closed")) == .of("edit_error_window"))
        #expect(editErrorMessage(ApiError(status: 403, code: "reposition_locked")) == .of("edit_error_locked"))
        #expect(editErrorMessage(ApiError(status: 400, code: "too_far")) == .of("edit_error_too_far"))
    }

    @Test func autoSaysWhenItIsOffline() {
        #expect(geocodeErrorMessage(nil) == .of("place_error_address"))
        #expect(geocodeErrorMessage(ApiError(status: 0, code: ApiError.network)) == .of("place_error_address_offline"))
    }

    private let placedAt = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theTextWindowIsFiveMinutesAndCountsDown() {
        let fresh = editRules(placedAt: placedAt, hasFinds: false, now: placedAt + 30)
        #expect(fresh.fullEdit)
        #expect(fresh.minutesLeft == 5)
        #expect(editRules(placedAt: placedAt, hasFinds: false, now: placedAt + stickerEditWindow - 0.001).minutesLeft == 1)
        let late = editRules(placedAt: placedAt, hasFinds: false, now: placedAt + stickerEditWindow)
        #expect(!late.fullEdit)
        #expect(late.minutesLeft == 1) // never below 1
    }

    @Test func aFoundBirdCannotMove() {
        #expect(editRules(placedAt: placedAt, hasFinds: false, now: placedAt).canMove)
        #expect(!editRules(placedAt: placedAt, hasFinds: true, now: placedAt).canMove)
    }

    private var draft: EditDraft { EditDraft(placeName: "  Banc du lac ", hint: "  ", description: "Vue", isPrivate: true, point: lausanne) }

    @Test func aFullEditSendsTrimmedTextAndClearsAnEmptyHintExplicitly() throws {
        let p = try #require(editPatch(original: lausanne, draft: draft, rules: EditRules(fullEdit: true, canMove: true, minutesLeft: 3)))
        #expect(p["placeName"] == "Banc du lac")
        // `null`, not absent: that is what clears it on the server.
        #expect(p["hint"] == .null)
        #expect(p["description"] == "Vue")
        #expect(p["isPrivate"] == true)
        // Not moved: no position sent.
        #expect(p["lng"] == nil && p["lat"] == nil)
        #expect(p.jsonString() == #"{"description":"Vue","hint":null,"isPrivate":true,"placeName":"Banc du lac"}"#)
    }

    @Test func aMovedPinIsSentOnlyWhileItMayMove() throws {
        let moved = with(draft) { $0.point = GeoPoint(lng: 6.6330, lat: 46.5200) }
        let p = try #require(editPatch(original: lausanne, draft: moved, rules: EditRules(fullEdit: true, canMove: true, minutesLeft: 3)))
        #expect(p["lng"] == .double(6.6330))
        #expect(p["lat"] == .double(46.5200))
        let frozen = try #require(editPatch(original: lausanne, draft: moved, rules: EditRules(fullEdit: true, canMove: false, minutesLeft: 3)))
        #expect(frozen["lng"] == nil)
    }

    @Test func afterTheWindowOnlyThePrivateFlagAndThePositionGo() throws {
        // Any text field would be refused with edit_window_closed.
        let moved = with(draft) { $0.point = GeoPoint(lng: 6.6330, lat: 46.5200) }
        let p = try #require(editPatch(original: lausanne, draft: moved, rules: EditRules(fullEdit: false, canMove: true, minutesLeft: 1)))
        #expect(Set(p.keys) == ["isPrivate", "lng", "lat"])
    }

    @Test func aBlankNameIsRefusedOnlyWhenTheNameIsEditable() {
        let blank = with(draft) { $0.placeName = "   " }
        #expect(editPatch(original: lausanne, draft: blank, rules: EditRules(fullEdit: true, canMove: true, minutesLeft: 3)) == nil)
        #expect(editPatch(original: lausanne, draft: blank, rules: EditRules(fullEdit: false, canMove: true, minutesLeft: 1)).map { Set($0.keys) } == ["isPrivate"])
    }
}

/// Android: ProfileBirdsTest — who placed them, and which picture a card may show
/// without spoiling the hunt.
struct ProfileBirdsTests {
    private let bob = with(SampleStickers.available) { $0.placedById = "u2"; $0.placedByName = "Bob"; $0.placementPhotoId = "pose" }

    @Test func onlyThisPlayersBirdsNewestFirst() {
        let old = with(bob) { $0.id = "old"; $0.placedAt = "2026-01-01T00:00:00.000Z" }
        let new = with(bob) { $0.id = "new"; $0.placedAt = "2026-09-01T00:00:00.000Z" }
        let other = with(bob) { $0.id = "other"; $0.placedById = "u3" }
        #expect(birdsPlacedBy([old, other, new], userId: "u2").map(\.id) == ["new", "old"])
    }

    @Test func aFoundBirdIsInColourItsPlacementPhotoFirst() {
        let found = with(bob) { $0.state = .found; $0.findPhotoId = "trophy" }
        #expect(birdThumb(found, hideSpoilers: true, revealed: false) == BirdThumb(photoId: "pose", tone: .color, blurred: false))
        // No placement photo: my trophy.
        #expect(birdThumb(with(found) { $0.placementPhotoId = nil }, hideSpoilers: false, revealed: false).photoId == "trophy")
    }

    @Test func myOwnBirdIsInColour() {
        #expect(birdThumb(with(bob) { $0.placedByMe = true }, hideSpoilers: false, revealed: false).tone == .color)
    }

    // Break the spoiler rule (show the photo sharp, or at all when spoilers are
    // off) and these go red: the profile must not hint more than the map does.
    @Test func aBirdNotFoundYetIsGreyAndStillASpoiler() {
        #expect(birdThumb(bob, hideSpoilers: false, revealed: false) == BirdThumb(photoId: "pose", tone: .grey, blurred: true))
        #expect(birdThumb(bob, hideSpoilers: false, revealed: true) == BirdThumb(photoId: "pose", tone: .grey, blurred: false))
        #expect(birdThumb(bob, hideSpoilers: true, revealed: true) == BirdThumb(photoId: nil, tone: .grey, blurred: false))
        #expect(birdThumb(with(bob) { $0.placementPhotoId = nil }, hideSpoilers: false, revealed: false) == BirdThumb(photoId: nil, tone: .grey, blurred: false))
    }
}

/// Android: FirstRunTest.
struct FirstRunTests {
    private let latest = "0.2"
    private let ready = with(UserPrefs.newAccount) { $0.termsAcceptedVersion = currentTermsVersion; $0.onboarded = true }

    @Test func termsComeFirst() {
        #expect(firstRunGate(.newAccount, lastSeenRelease: "0.1", latestRelease: latest) == .terms)
        #expect(firstRunGate(with(ready) { $0.termsAcceptedVersion = "2020-01-01" }, lastSeenRelease: latest, latestRelease: latest) == .terms)
    }

    @Test func noOnboardingGate() {
        // No onboarding popup: the welcome carousel stands in for it, and the account is marked.
        let fresh = with(ready) { $0.onboarded = false }
        #expect(firstRunGate(fresh, lastSeenRelease: latest, latestRelease: latest) == nil)
        #expect(shouldMarkOnboarded(fresh))
        #expect(!shouldMarkOnboarded(ready))
    }

    @Test func releaseNotesOnlyAfterAnUpdate() {
        #expect(firstRunGate(ready, lastSeenRelease: "0.1", latestRelease: latest) == .releaseNotes)
        #expect(firstRunGate(ready, lastSeenRelease: latest, latestRelease: latest) == nil)
        // First install on this phone: nothing is "new" yet.
        #expect(firstRunGate(ready, lastSeenRelease: nil, latestRelease: latest) == nil)
    }

    @Test func aNewcomerHasTheLatestNotesMarkedSeenSilently() {
        #expect(shouldSilentlyMarkReleaseSeen(ready, lastSeenRelease: nil, latestRelease: latest))
        #expect(shouldSilentlyMarkReleaseSeen(with(ready) { $0.onboarded = false }, lastSeenRelease: "0.1", latestRelease: latest))
        // A returning player on an update sees them instead.
        #expect(!shouldSilentlyMarkReleaseSeen(ready, lastSeenRelease: "0.1", latestRelease: latest))
        #expect(!shouldSilentlyMarkReleaseSeen(ready, lastSeenRelease: latest, latestRelease: latest))
    }

    @Test func releaseVersionsAreUnique() {
        #expect(Set(appReleases.map(\.version)).count == appReleases.count)
    }
}

/// Android: CollectionTest.
struct CollectionTests {
    private func placed(_ id: String, _ name: String, _ at: String, finds: Int = 0, country: String? = "CH", archived: Bool = false, reported: Bool = false) -> MyPlacedSticker {
        MyPlacedSticker(
            id: id, lng: 6.6, lat: 46.5, placeName: name, placedAt: at, countryCode: country,
            status: archived ? .archived : .active, isPrivate: false, findCount: finds, reportCount: reported ? 1 : 0, hasOpenReport: reported
        )
    }

    private func found(_ id: String, _ name: String, _ at: String, country: String? = "CH") -> CollectionItem {
        CollectionItem(
            stickerId: "s-\(id)", findId: id, foundAt: at, foundLng: 6.6, foundLat: 46.5, findPhotoId: "p", placeName: name,
            placedById: "bob", placedByName: "Bob", countryCode: country, placedAt: at, status: .active
        )
    }

    private var banc: MyPlacedSticker { placed("a", "Banc du lac", "2026-09-01T10:00:00Z", finds: 3) }
    private var ecluse: MyPlacedSticker { placed("b", "Écluse", "2026-09-20T10:00:00Z", finds: 1, country: "FR", archived: true) }
    private var gare: MyPlacedSticker { placed("c", "gare", "2026-08-10T10:00:00Z", finds: 7, country: nil, reported: true) }
    private var hidden: [MyPlacedSticker] { [banc, ecluse, gare] }

    @Test func theDefaultIsMostRecentFirst() {
        #expect(visibleHidden(hidden, CollectionFilters(), CollectionSort()).map(\.id) == ["b", "a", "c"])
        #expect(CollectionSort().isDefault)
    }

    @Test func alphabeticalIgnoresCaseAndAccentsLikeLocaleCompare() {
        let az = visibleHidden(hidden, CollectionFilters(), CollectionSort(.alpha, descending: false))
        #expect(az.map(\.placeName) == ["Banc du lac", "Écluse", "gare"])
    }

    @Test func placedBirdsSortByHowOftenTheyWereFound() {
        #expect(visibleHidden(hidden, CollectionFilters(), CollectionSort(.finds)).map(\.id) == ["c", "a", "b"])
    }

    @Test func theFoundTabHasNoFindsSort() {
        #expect(sortKeysFor(.found) == [.date, .alpha])
        #expect(sortForTab(CollectionSort(.finds, descending: false), .found) == CollectionSort(.date, descending: false))
        #expect(sortForTab(CollectionSort(.finds), .hidden) == CollectionSort(.finds))
    }

    @Test func filtersCombine() {
        #expect(visibleHidden(hidden, CollectionFilters(statuses: [.archived]), CollectionSort()).map(\.id) == ["b"])
        #expect(visibleHidden(hidden, CollectionFilters(reportedOnly: true), CollectionSort()).map(\.id) == ["c"])
        // An unknown country is its own choice.
        let unknownOrFr = CollectionFilters(countries: [unknownCountry, "FR"])
        #expect(Set(visibleHidden(hidden, unknownOrFr, CollectionSort()).map(\.id)) == ["b", "c"])
        #expect(unknownOrFr.active)
        #expect(!CollectionFilters().active)
    }

    @Test func theFoundTabFiltersByCountryOnly() {
        let list = [found("1", "Banc", "2026-09-01T10:00:00Z"), found("2", "Lac", "2026-09-02T10:00:00Z", country: "FR")]
        #expect(visibleFound(list, CollectionFilters(countries: ["CH"]), CollectionSort()).map(\.findId) == ["1"])
    }

    // A stale filter must never hide everything.
    @Test func filtersWhoseCategoryIsGoneAreDropped() {
        let f = CollectionFilters(statuses: [.archived], reportedOnly: true, countries: ["CH", "IT"])
        #expect(pruneFilters(f, tab: .hidden, hasArchived: false, reportedCount: 0, countries: ["CH"]) == CollectionFilters(countries: ["CH"]))
        // Status and reports only exist on « Cachés ».
        #expect(pruneFilters(f, tab: .found, hasArchived: true, reportedCount: 3, countries: ["CH"]) == CollectionFilters(countries: ["CH"]))
        // Nothing to drop: unchanged.
        let ok = CollectionFilters(countries: ["CH"])
        #expect(pruneFilters(ok, tab: .hidden, hasArchived: true, reportedCount: 1, countries: ["CH"]) == ok)
    }

    @Test func onlyFiltersWithSomethingBehindThemAreOffered() {
        #expect(filterAvailability(.hidden, hasArchived: true, reportedCount: 1, countryCount: 2) == FilterAvailability(status: true, reported: true, countries: true))
        #expect(!filterAvailability(.found, hasArchived: true, reportedCount: 1, countryCount: 1).any)
        #expect(!filterAvailability(.hidden, hasArchived: false, reportedCount: 0, countryCount: 1).any)
    }

    @Test func groupsKeepTheSortedOrder() {
        let sorted = visibleHidden(hidden, CollectionFilters(), CollectionSort())
        let groups = groupSections(sorted, key: { $0.countryCode ?? unknownCountry }, label: { $0.countryCode ?? "?" })
        #expect(groups.map(\.key) == ["FR", "CH", unknownCountry])
        #expect(groups[1].items.map(\.id) == ["a"])
    }

    @Test func namesAreInTheReadersLanguage() {
        let fr = Locale(identifier: "fr_CH")
        #expect(countryName("CH", locale: fr) == "Suisse")
        #expect(countryName("ch", locale: Locale(identifier: "de")) == "Schweiz")
        #expect(countryName(unknownCountry, locale: fr) == nil)
        #expect(countryName(nil, locale: fr) == nil)
        #expect(monthLabel("2026-09-20T10:00:00Z", locale: fr, timeZone: TimeZone(identifier: "Europe/Zurich")!) == "septembre 2026")
    }

    @Test func statsSayWhatTheTabsDoNot() {
        #expect(collectionStats(.hidden, found: [], hidden: hidden) == CollectionStats(finds: 11, countries: 2))
        #expect(collectionStats(.found, found: [found("1", "x", "2026-01-01T00:00:00Z")], hidden: hidden) == CollectionStats(finds: 0, countries: 1))
    }
}

/// Android: DeepLinkTest (the manifest and assetlinks checks are Android's; the
/// iOS claim is the app's associated domains, outside OiseauCore).
struct DeepLinkTests {
    private func open(_ path: String) -> DeepLink? { DeepLink.parse("https://oiseaupourri.ch\(path)") }

    /// Every web page the app opens itself, and what it opens.
    private let pages: [String: DeepLink] = [
        "/": .welcome(.landing),
        "/login": .welcome(.login),
        "/place": .screen(.place),
        "/collection": .screen(.collection),
        "/leaderboard": .screen(.leaderboard),
        "/profile": .screen(.profile),
        "/settings": .screen(.settings),
        "/settings/compte": .account(),
        "/settings/preferences": .screen(.preferences),
        "/commander-oiseaux": .screen(.order),
        "/commander-oiseaux/historique": .screen(.orderHistory),
        "/reset-password": .resetPassword(nil),
    ]

    @Test func theWebPagesOpenTheirScreen() {
        for (path, link) in pages { #expect(open(path) == link, "\(path)") }
        #expect(open("/u/abc-123") == .profile("abc-123"))
        // As typed or as a browser normalises it.
        #expect(DeepLink.parse("https://oiseaupourri.ch") == .welcome(.landing))
        #expect(open("/collection/") == .screen(.collection))
    }

    @Test func theOthersStayWhereTheyAre() {
        for path in ["/u/", "/u/a/b", "/inconnu", "/settings/admin", "/settings/parrainage", "/auth/verify-email", "/api/map"] {
            #expect(open(path) == nil, "\(path)")
        }
        #expect(DeepLink.parse("not a url at all %%") == nil)
    }

    // The links our e-mails carry, as the API's integration suite recorded them
    // (androidContract.test.ts): change their shape there and this goes red.
    @Test func theEmailedLinksOpenInTheApp() throws {
        let links = try JSONDecoder().decode([String: String].self, from: try fixture("email-links.json"))
        #expect(DeepLink.parse(links["resetPassword"]!) == .resetPassword("token"))
        #expect(DeepLink.parse(links["verifyEmail"]!) == .verifyEmail(token: "token", landing: .verified))
        #expect(DeepLink.parse(links["approveEmailChange"]!) == .verifyEmail(token: "token", landing: .approved))
    }

    @Test func theSignUpLinkOpensTheSignUp() {
        #expect(open("/login?mode=register") == .welcome(.register))
        // The old referral links (`?ref=`, retired in v4) still open the page they point to.
        #expect(open("/?ref=K7Q2") == .welcome(.landing))
    }

    @Test func theAccountPageAsTheWebLandsThere() {
        #expect(open("/settings/compte?email=verified") == .account(landed: .verified))
        #expect(open("/settings/compte?email=approved&error=INVALID_TOKEN") == .account(landed: .approved, failed: true))
    }

    /// What the app's associated-domains claim must list (the Android manifest's twin).
    @Test func theClaimedPathsAreExactlyThePagesTheAppOpens() {
        #expect(Set(DeepLink.claimedPaths) == Set(pages.keys).union(["/auth/verify-email"]))
    }
}

/// Android: OfflineMapsTest — what an offline zone costs, and when the automatic one moves.
struct OfflineMapsTests {
    private let lausanne = GeoPoint(lng: 6.6323, lat: 46.5197)

    @Test func tilesFollowTheSlippyGrid() {
        let world = GeoBounds(south: -85, west: -180, north: 85, east: 179.999)
        #expect(tileCount(world, minZoom: 0, maxZoom: 0) == 1)
        #expect(tileCount(world, minZoom: 0, maxZoom: 1) == 1 + 4)
        // A point-sized box is one tile per zoom.
        let dot = GeoBounds(south: 46.5197, west: 6.6323, north: 46.5197, east: 6.6323)
        #expect(tileCount(dot, minZoom: 10, maxZoom: 16) == 7)
    }

    @Test func aDistrictFitsAndACountryDoesNot() {
        let district = boundsAround(lausanne, radiusM: 1_500)
        let switzerland = GeoBounds(south: 45.8, west: 5.9, north: 47.8, east: 10.5)
        #expect(fitsInBudget(used: 0, estimate: estimateZoneBytes(district, .quartier)))
        #expect(!fitsInBudget(used: 0, estimate: estimateZoneBytes(switzerland, .quartier)))
        // « Ville » stops at zoom 14: a whole region gets within reach.
        #expect(estimateZoneBytes(switzerland, .ville) < estimateZoneBytes(switzerland, .quartier) / 10)
    }

    @Test func theAutomaticZoneFitsTheBudgetOnItsOwn() {
        #expect(fitsInBudget(used: 0, estimate: estimateZoneBytes(boundsAround(lausanne, radiusM: autoZoneRadiusM), .quartier)))
    }

    @Test func theBudgetCountsWhatIsAlreadyKept() {
        #expect(fitsInBudget(used: zonesMaxBytes - 10, estimate: 10))
        #expect(!fitsInBudget(used: zonesMaxBytes - 10, estimate: 11))
    }

    @Test func boundsAroundSpanTheRadiusBothWays() {
        let b = boundsAround(lausanne, radiusM: 3_000)
        #expect(abs(distanceM(GeoPoint(lng: lausanne.lng, lat: b.south), GeoPoint(lng: lausanne.lng, lat: b.north)) - 6_000) < 60)
        #expect(abs(distanceM(GeoPoint(lng: b.west, lat: lausanne.lat), GeoPoint(lng: b.east, lat: lausanne.lat)) - 6_000) < 60)
    }

    // A median, so a weekend away doesn't move home.
    @Test func homeIsTheMedianOfLaunchesAndNeedsAFew() {
        #expect(homeCenter([lausanne, lausanne]) == nil)
        let zermatt = GeoPoint(lng: 7.7491, lat: 46.0207)
        #expect(homeCenter([lausanne, lausanne, lausanne, zermatt, lausanne]) == lausanne)
    }

    @Test func launchPositionsAreKeptCoarse() {
        #expect(coarse(lausanne) == GeoPoint(lng: 6.632, lat: 46.52))
        let many = (0..<25).reduce([GeoPoint]()) { acc, _ in addHomeSample(acc, lausanne) }
        #expect(many.count == homeSamplesMax)
    }

    @Test func theAutomaticZoneMovesOnlyWhenItShould() {
        #expect(planAutoZone(home: nil, existingCenter: nil, existingAgeDays: nil, existingStyleMatches: true) == .nothing)
        #expect(planAutoZone(home: lausanne, existingCenter: nil, existingAgeDays: nil, existingStyleMatches: true) == .download)
        #expect(planAutoZone(home: lausanne, existingCenter: GeoPoint(lng: 6.635, lat: 46.52), existingAgeDays: 3, existingStyleMatches: true) == .nothing)
        #expect(planAutoZone(home: lausanne, existingCenter: GeoPoint(lng: 6.70, lat: 46.52), existingAgeDays: 3, existingStyleMatches: true) == .replace) // > 1 km
        #expect(planAutoZone(home: lausanne, existingCenter: lausanne, existingAgeDays: autoZoneRefreshDays, existingStyleMatches: true) == .replace)
        #expect(planAutoZone(home: lausanne, existingCenter: lausanne, existingAgeDays: 1, existingStyleMatches: false) == .replace) // other style
    }

    @Test func zoneMetaRoundTrips() throws {
        let m = ZoneMeta(name: "Lausanne", kind: .auto, styleId: "liberty", createdAt: 1_790_000_000_000, centerLng: 6.6, centerLat: 46.5)
        #expect(try ApiJson.decoder.decode(ZoneMeta.self, from: ApiJson.encoder.encode(m)) == m)
        #expect(m.center == GeoPoint(lng: 6.6, lat: 46.5))
    }
}
