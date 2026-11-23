import SwiftUI
import Observation
import OiseauCore

/// What an edit starts from: a bird of the map or of my collection.
struct EditTarget {
    let stickerId: String
    /// Where the bird is now: the reposition map's starting point.
    let origin: GeoPoint
    /// Read once on open: if the window closes mid-edit, the server still refuses stale fields.
    let rules: EditRules
    let draft: EditDraft

    init(map s: MapSticker, now: Date = Date()) {
        stickerId = s.id
        origin = s.point
        rules = editRules(placedAt: parseIsoDate(s.placedAt) ?? .distantPast, hasFinds: s.hasFinds == true, now: now)
        draft = EditDraft.of(s)
    }

    init(placed s: MyPlacedSticker, now: Date = Date()) {
        stickerId = s.id
        origin = GeoPoint(lng: s.lng, lat: s.lat)
        rules = editRules(placedAt: parseIsoDate(s.placedAt) ?? .distantPast, hasFinds: s.findCount > 0, now: now)
        draft = EditDraft(placeName: s.placeName, hint: s.hint ?? "", description: s.description ?? "", isPrivate: s.isPrivate, point: origin)
    }
}

/// Editing a placed bird (Android: ui/place/EditStickerSheet.kt, EditViewModel.kt):
/// the texts for 5 minutes, the position while nobody found it, privacy always.
struct EditStickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: EditTarget
    @State private var draft: EditDraft
    @State private var busy = false
    @State private var error: UiText?

    init(target: EditTarget) {
        self.target = target
        _draft = State(initialValue: target.draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if target.rules.fullEdit {
                        HelpLine(icon: nil, text: L("edit_minutes_left", target.rules.minutesLeft))
                        OpTextField(label: L("place_name"), text: $draft.placeName)
                        OpTextField(label: L("place_hint"), text: $draft.hint)
                        MultilineField(label: L("place_description"), text: $draft.description, maxLength: 2000)
                    } else {
                        HelpLine(icon: "lock", text: L("edit_locked"))
                    }
                    if target.rules.canMove {
                        Text(L("edit_reposition")).font(.zBody).foregroundStyle(Zine.muted)
                        PlacementMapCard(styleURL: MapStyle.of(app.prefs?.mapStyle).url, center: target.origin, initial: draft.point) { draft.point = $0 }
                        HelpLine(icon: "move", text: L("edit_reposition_help", Int(maxPlacementAdjustM)))
                    } else {
                        HelpLine(icon: "lock", text: L("edit_position_frozen"))
                    }
                    PrivateToggle(isOn: $draft.isPrivate)
                    if let error { Text(error.text).font(.zBody).foregroundStyle(Zine.error) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Zine.panel)
            .navigationTitle(L("edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(busy ? "edit_busy" : "edit_save")) { Task { await save() } }
                        .font(.syne(16, 700))
                        .disabled(busy)
                }
            }
        }
        .tint(Zine.ink)
    }

    private func save() async {
        guard let patch = editPatch(original: target.origin, draft: draft, rules: target.rules) else {
            error = .of("edit_error_empty_name")
            return
        }
        busy = true
        error = nil
        do {
            _ = try await app.place.edit(target.stickerId, patch: patch)
            dismiss()
        } catch let e as ApiError {
            error = editErrorMessage(e)
        } catch {
            self.error = uiText(error)
        }
        busy = false
    }
}
