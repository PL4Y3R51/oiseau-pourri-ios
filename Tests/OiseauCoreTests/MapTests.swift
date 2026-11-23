import Foundation
import Testing
@testable import OiseauCore

private let available = SampleStickers.available
private let found = SampleStickers.found
private let mine = SampleStickers.mine
private let archived = SampleStickers.archived

private func with(_ s: MapSticker, _ change: (inout MapSticker) -> Void) -> MapSticker {
    var copy = s
    change(&copy)
    return copy
}

/// The map's client rules (Android: MapRulesTest).
struct MapRulesTests {
    @Test func pinKindPrecedence() {
        #expect(available.pinKind == .available)
        #expect(found.pinKind == .found)
        // The server marks own birds 'found'; they still draw as mine.
        #expect(mine.pinKind == .mine)
        // Archived beats everything, own birds included.
        #expect(with(mine) { $0.status = .archived }.pinKind == .archived)
        #expect(archived.pinKind == .archived)
    }

    @Test func pinStyleCarriesTheBadges() {
        let s = mine.pinStyle
        #expect(s.reported)
        #expect(s.isPrivate)
        #expect(!s.wish)
        #expect(with(available) { $0.wishlisted = true }.pinStyle.spriteId == "pin-available-wish")
        #expect(PinStyle.all.count == 32)
        #expect(Set(PinStyle.all.map(\.spriteId)).count == 32)
    }

    @Test func ownBirdsAreNotFinds() {
        #expect(found.foundByMe)
        #expect(!mine.foundByMe)
        #expect(!available.foundByMe)
    }

    @Test func defaultFiltersHideArchivedOnly() {
        #expect(MapFilters().apply([available, found, mine, archived]) == [available, found, mine])
        #expect(MapFilters().deviations == 0)
    }

    @Test func hidingPrivateAndShowingArchived() {
        let f = MapFilters(showArchived: true, showPrivate: false)
        #expect(f.apply([available, found, mine, archived]) == [available, found, archived])
        #expect(f.deviations == 2)
    }

    @Test func categoriesCombineWithOr() {
        let wished = with(available) { $0.id = "w"; $0.wishlisted = true }
        let f = MapFilters(active: [.mine, .wishlist])
        #expect(f.apply([available, found, mine, archived, wished]) == [mine, wished])
        #expect(f.deviations == 2)
        #expect(f.toggled(.mine).active == [.wishlist])
    }

    @Test func toFindExcludesArchivedAndFound() {
        #expect(MapFilter.toFind.matches(available))
        #expect(!MapFilter.toFind.matches(found))
        #expect(!MapFilter.toFind.matches(with(archived) { $0.state = .available }))
        #expect(!MapFilter.found.matches(mine))
        #expect(MapFilter.reported.matches(mine))
        #expect(!MapFilter.reported.matches(with(found) { $0.hasOpenReport = true }))
    }

    @Test func filterRowsShowOnlyCategoriesWithBirdsOrSwitchedOn() {
        let rows = filterRows([available, found], MapFilters(active: [.reported]))
        #expect(rows.map(\.filter) == [.toFind, .found, .reported])
        #expect(rows.last?.count == 0)
        #expect(rows.last?.on == true)
    }

    @Test func stackedPinsWithinTheThreshold() {
        let a = with(available) { $0.id = "a" }, b = with(available) { $0.id = "b" }, c = with(available) { $0.id = "c" }
        let screen: [String: (x: Double, y: Double)] = ["a": (100, 100), "b": (115, 110), "c": (140, 100)]
        #expect(stackedWith(a, [a, b, c], threshold: 22) { screen[$0.id]! } == [a, b]) // c is 40 pt away
    }

    @Test func menuForAHunter() {
        #expect(stickerActions(available) == [.report, .wishlist, .placerProfile])
        // Already caught: no wishlist, but it can still be reported missing.
        #expect(stickerActions(found) == [.openInCollection, .report, .placerProfile])
        // Archived: nothing to report or wish for.
        #expect(stickerActions(archived) == [.placerProfile])
        // The deleted-accounts ghost has no profile.
        #expect(stickerActions(with(available) { $0.placedById = deletedUserId }) == [.report, .wishlist])
    }

    @Test func menuForThePlacer() {
        #expect(stickerActions(mine) == [.openInCollection, .makePrivate, .archive, .delete])
    }

    @Test func editWindowIsFiveMinutes() {
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(isStickerEditable(placedAt: t0, now: t0.addingTimeInterval(stickerEditWindow - 0.001)))
        #expect(!isStickerEditable(placedAt: t0, now: t0.addingTimeInterval(stickerEditWindow)))
    }

    @Test func geoPointRoundTripsWhateverTheLocale() {
        let p = GeoPoint(lng: 6.6323, lat: 46.5197)
        #expect(GeoPoint.parse(p.format()) == p)
        #expect(p.label() == "46.51970, 6.63230")
        #expect(GeoPoint.parse("6.6") == nil)
    }

    @Test func distancesAndClamping() {
        let a = GeoPoint.lausanne
        let b = GeoPoint(lng: 6.6323, lat: 46.5197 + 0.001) // ~111 m north
        #expect(abs(distanceM(a, b) - 111.2) < 0.5)
        let clamped = clampToRadius(a, b, maxM: maxPlacementAdjustM)
        #expect(abs(distanceM(a, clamped) - 100) < 0.01)
        #expect(clampToRadius(a, a, maxM: 10) == a)
        let ring = circleRing(a, radiusM: 50, points: 8)
        #expect(ring.count == 9)
        #expect(ring.allSatisfy { abs(distanceM(a, $0) - 50) < 0.01 })
    }

    @Test func mapStyles() {
        #expect(MapStyle.of(nil) == .liberty)
        #expect(MapStyle.of("positron").url.absoluteString == "https://tiles.openfreemap.org/styles/positron")
        #expect(MapStyle.of("neon") == .liberty)
        #expect(MapStyle.bright.label == "Bright")
    }
}

/// The map's data (Android: MapRepositoryTest, the read part).
@MainActor
struct MapRepositoryTests {
    private func map(_ server: ScriptedTransport, _ list: [MapSticker]) async throws {
        await server.enqueue(.respond(HttpResponse(status: 200, body: try ApiJson.encoder.encode(list))))
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("map-\(UUID().uuidString).json")
    }

    @Test func refetchesOnlyOnceAMinuteOld() async throws {
        let server = ScriptedTransport()
        var now = Date(timeIntervalSince1970: 1_000)
        let repo = MapRepository(api: client(server), clock: { now })
        try await map(server, [available])
        try await repo.refreshIfStale()
        #expect(await server.requestCount == 1)

        now += MapRepository.staleAfter - 1
        try await repo.refreshIfStale()
        #expect(await server.requestCount == 1)

        now += 2
        try await map(server, [available, found])
        try await repo.refreshIfStale()
        #expect(await server.requestCount == 2)
        #expect(repo.stickers?.count == 2)
    }

    // A cold start without network still shows the pins of the last session.
    @Test func theLastMapIsKeptOnDiskForAnOfflineStart() async throws {
        let server = ScriptedTransport()
        let file = tempFile()
        try await map(server, [available, found])
        try await MapRepository(api: client(server), snapshot: file).refresh()
        #expect(FileManager.default.fileExists(atPath: file.path))

        await server.close() // no network now
        let cold = MapRepository(api: client(server), snapshot: file)
        let e = await apiError { try await cold.refresh() }
        #expect(e?.code == ApiError.network)
        #expect(cold.stickers?.map(\.id) == [available.id, found.id])
        // Still stale: the next chance at a network refetches.
        #expect(cold.isStale())

        cold.clear() // sign-out: someone else may sign in next
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(cold.stickers == nil)
    }

    // Issue #89: the API down behind nginx (502) is no different for the player.
    @Test func theLastMapAlsoShowsWhileTheServerIsDown() async throws {
        let server = ScriptedTransport()
        let file = tempFile()
        try await map(server, [available])
        try await MapRepository(api: client(server), snapshot: file).refresh()

        await server.json(502, "<html>502 Bad Gateway</html>")
        let cold = MapRepository(api: client(server), snapshot: file)
        let e = await apiError { try await cold.refresh() }
        #expect(e?.isUnavailable == true)
        #expect(cold.stickers?.map(\.id) == [available.id])
    }

    // A refusal is not "offline": nothing is restored over it.
    @Test func aRefusalDoesNotRestoreTheSnapshot() async throws {
        let server = ScriptedTransport()
        let file = tempFile()
        try await map(server, [available])
        try await MapRepository(api: client(server), snapshot: file).refresh()

        await server.json(401, #"{"error":"Authentication required"}"#)
        let cold = MapRepository(api: client(server), snapshot: file)
        _ = await apiError { try await cold.refresh() }
        #expect(cold.stickers == nil)
    }

    @Test func listenersHearEveryChange() async throws {
        let server = ScriptedTransport()
        let repo = MapRepository(api: client(server))
        var heard: [Int?] = []
        repo.onChange = { heard.append($0?.count) }
        try await map(server, [available, found])
        try await repo.refresh()
        repo.clear()
        #expect(heard == [2, nil])
    }
}
