import Foundation

// Placing and editing a bird (Android: domain/Placement.kt; web: PlacePage.tsx,
// EditStickerSheet.tsx). The server enforces every rule here — the radius around
// the device, the 5-minute text window, the position frozen once found; these only
// keep the form honest and word its answers.

/// What the place form sends (web: PlacePage#submit).
public struct PlacementDraft: Hashable, Sendable {
    /// The fine-tuned point: what is saved.
    public var point: GeoPoint
    /// Where the device is: the server refuses a point dragged beyond the radius from it.
    public var device: GeoPoint
    public var placeName: String
    public var hint: String
    public var description: String
    public var isPrivate: Bool

    public init(point: GeoPoint, device: GeoPoint, placeName: String, hint: String, description: String, isPrivate: Bool) {
        self.point = point
        self.device = device
        self.placeName = placeName
        self.hint = hint
        self.description = description
        self.isPrivate = isPrivate
    }
}

/// web: `- ajusté à N m de ta position`, 0 when the target sits on the device.
public func adjustedM(_ device: GeoPoint, _ chosen: GeoPoint) -> Int { Int(distanceM(device, chosen).rounded()) }

/// What the place form says when the server refuses (web: PlacePage#submit).
public func placeErrorMessage(_ e: ApiError) -> UiText {
    // Only when the bird couldn't be parked either (storage refused it).
    if e.isUnavailable { return .of("place_error_network") }
    switch e.code {
    case "too_far_from_device": return .of("place_error_too_far")
    case "photo_required": return .of("place_error_photo")
    default: return .raw(e.message ?? e.code)
    }
}

/// « Auto » found nothing (web: PlacePage#fillAddress) — no server is said as such.
public func geocodeErrorMessage(_ e: ApiError?) -> UiText {
    .of(e?.isUnavailable == true ? "place_error_address_offline" : "place_error_address")
}

/// What the edit sheet says when the server refuses (web: EditStickerSheet, server messages).
public func editErrorMessage(_ e: ApiError) -> UiText {
    if e.isUnavailable { return e.toUiText() }
    switch e.code {
    case "edit_window_closed": return .of("edit_error_window")
    case "reposition_locked": return .of("edit_error_locked")
    case "too_far": return .of("edit_error_too_far")
    default: return .raw(e.message ?? e.code)
    }
}

/// The edit sheet's two independent rules, read once when it opens (web: EditStickerSheet).
public struct EditRules: Hashable, Sendable {
    /// Name, hint and description: within [stickerEditWindow] of placement.
    public var fullEdit: Bool
    /// Position: as long as nobody has found the bird (shared canRepositionSticker).
    public var canMove: Bool
    /// web: `~N min` left, never below 1.
    public var minutesLeft: Int

    public init(fullEdit: Bool, canMove: Bool, minutesLeft: Int) {
        self.fullEdit = fullEdit
        self.canMove = canMove
        self.minutesLeft = minutesLeft
    }
}

public func editRules(placedAt: Date, hasFinds: Bool, now: Date) -> EditRules {
    let left = stickerEditWindow - now.timeIntervalSince(placedAt)
    return EditRules(
        fullEdit: isStickerEditable(placedAt: placedAt, now: now),
        canMove: !hasFinds,
        minutesLeft: max(1, Int((left / 60).rounded(.up)))
    )
}

/// The edit form's fields, as typed.
public struct EditDraft: Hashable, Sendable {
    public var placeName: String
    public var hint: String
    public var description: String
    public var isPrivate: Bool
    public var point: GeoPoint

    public init(placeName: String, hint: String, description: String, isPrivate: Bool, point: GeoPoint) {
        self.placeName = placeName
        self.hint = hint
        self.description = description
        self.isPrivate = isPrivate
        self.point = point
    }

    public static func of(_ s: MapSticker) -> EditDraft {
        EditDraft(placeName: s.placeName, hint: s.hint ?? "", description: s.description ?? "", isPrivate: s.isPrivate, point: s.point)
    }
}

/// The PATCH body for an edit, or nil when the name is blank (web: « Le nom du lieu
/// ne peut pas être vide. »). A JSON object, not the generated body: clearing a hint
/// means sending `"hint": null`, which a body with nil fields left out can't say.
///
/// Text fields go only while [EditRules.fullEdit] — the server answers
/// `edit_window_closed` to any of them later; the private flag always goes; the
/// position only when it moved and may still move.
public func editPatch(original: GeoPoint, draft: EditDraft, rules: EditRules) -> JsonObject? {
    let name = draft.placeName.trimmingCharacters(in: .whitespacesAndNewlines)
    if rules.fullEdit && name.isEmpty { return nil }
    var p: JsonObject = [:]
    if rules.fullEdit {
        p["placeName"] = .string(name)
        let hint = draft.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        p["hint"] = hint.isEmpty ? .null : .string(hint)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        p["description"] = description.isEmpty ? .null : .string(description)
    }
    p["isPrivate"] = .bool(draft.isPrivate)
    if rules.canMove && draft.point != original {
        p["lng"] = .double(draft.point.lng)
        p["lat"] = .double(draft.point.lat)
    }
    return p
}
