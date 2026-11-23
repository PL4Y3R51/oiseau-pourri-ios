import Foundation

/// Placing and editing birds (`POST /api/stickers`, `PATCH /api/stickers/:id`,
/// `GET /api/geocode/reverse`; Android: data/PlaceRepository.kt). The map is
/// refetched after either, so the new or moved pin is there when the player looks.
@MainActor
public final class PlaceRepository {
    private let api: ApiClient
    private let map: MapRepository

    public init(api: ApiClient, map: MapRepository) {
        self.api = api
        self.map = map
    }

    /// web: PlacePage#submit (and the offline replay) — same multipart fields. Empty
    /// texts are left out: the server then reverse-geocodes the place name, so it is
    /// never blank. Returns the new bird's id.
    @discardableResult
    public func place(_ d: PlacementDraft, photo: Data?, clientToken: String? = nil, capturedAt: Int64? = nil) async throws(ApiError) -> String {
        var form = MultipartForm()
        form.add("lng", "\(d.point.lng)")
        form.add("lat", "\(d.point.lat)")
        form.add("deviceLng", "\(d.device.lng)")
        form.add("deviceLat", "\(d.device.lat)")
        let name = d.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { form.add("placeName", name) }
        if !d.hint.isBlank { form.add("hint", d.hint) }
        if !d.description.isBlank { form.add("description", d.description) }
        // The server coerces any non-empty string to true ("0" included): only send it when on.
        if d.isPrivate { form.add("isPrivate", "1") }
        if let photo { form.add("photo", filename: "placement.jpg", data: photo) }
        // A replay's capture time; the token goes with the live call too, so a try whose
        // answer was lost (timeout) and is then replayed still plants one bird.
        if let capturedAt { form.add("capturedAt", "\(capturedAt)") }
        if let clientToken { form.add("clientToken", clientToken) }
        let created = try await api.postForm("/api/stickers", form, as: CreatedResponse.self, timeout: ApiClient.gestureTimeout)
        try? await map.refresh()
        guard let id = created?.id else { throw ApiError(status: 500, code: ApiError.unknown) }
        return id
    }

    /// web: EditStickerSheet#submit. [patch] comes from [editPatch]; may be parked (issue #89).
    @discardableResult
    public func edit(_ id: String, patch: JsonObject) async throws(ApiError) -> Sent {
        try await map.edit(id, body: patch)
    }

    /// The « Auto » button: the address under the point, or nil when there is none.
    public func address(at: GeoPoint) async throws(ApiError) -> String? {
        let res = try await api.get("/api/geocode/reverse?lng=\(at.lng)&lat=\(at.lat)", as: ReverseGeocodeResponse.self)
        guard let address = res?.address, !address.isBlank else { return nil }
        return address
    }
}
