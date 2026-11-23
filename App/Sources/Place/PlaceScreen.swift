import SwiftUI
import Observation
import OiseauCore

// Placing a bird (Android: ui/place/PlaceViewModel.kt, PlaceScreen.kt, CharterSlides.kt).

@MainActor
@Observable
final class PlaceModel {
    /// The device's fix: the centre of the allowed circle.
    private(set) var position: Position?
    /// The fine-tuned target, the device position by default.
    var chosen: GeoPoint?
    var placeName = ""
    var hint = "" { didSet { if hint.count > 500 { hint = String(hint.prefix(500)) } } }
    var description = "" { didSet { if description.count > 2000 { description = String(description.prefix(2000)) } } }
    var isPrivate = false
    private(set) var photo: Data?
    private(set) var error: UiText?
    private(set) var busy = false
    /// « Auto » is looking up the address.
    private(set) var geoBusy = false
    /// No network or no server: the bird waits on the device (« Gardé au chaud »).
    private(set) var queued = false
    private(set) var queuedCause: Unavailable = .noNetwork

    var canSubmit: Bool { !busy && position != nil && chosen != nil }

    func locate(_ location: LocationService) async {
        let p = await location.current(maxAge: 30, timeout: 15)
        if let p {
            position = p
            if chosen == nil { chosen = p.point }
            if error == .of("hunt_no_position") { error = nil }
        } else if position == nil {
            error = .of("hunt_no_position")
        }
    }

    func setPhoto(_ data: Data?) {
        if let data { photo = data; error = nil } else { error = .of("hunt_bad_photo") }
    }

    /// The address under the chosen point.
    func fillAddress(_ app: AppModel) async {
        guard let at = chosen else { return }
        geoBusy = true
        error = nil
        do {
            if let address = try await app.place.address(at: at) { placeName = address } else { error = geocodeErrorMessage(nil) }
        } catch let e as ApiError {
            error = geocodeErrorMessage(e)
        } catch {
            self.error = geocodeErrorMessage(nil)
        }
        geoBusy = false
    }

    /// True once the server has the bird (the form is then reset for the next one).
    func submit(_ app: AppModel) async -> Bool {
        guard let position, let chosen else {
            error = .of("place_no_position")
            return false
        }
        guard canSubmit else { return false }
        // A bird is placed with its photo, as a find is made with one (spec §4.2).
        guard let photo else {
            error = .of("place_error_photo")
            return false
        }
        busy = true
        error = nil
        let draft = PlacementDraft(point: chosen, device: position.point, placeName: placeName, hint: hint, description: description, isPrivate: isPrivate)
        // One token for this bird, live try and replay alike: if the server took it but
        // the answer was lost, the replay finds it instead of planting a second.
        let token = UUID().uuidString.lowercased()
        if app.reach == .noNetwork, park(app, draft, position, photo, token, .noNetwork) { return false }
        do {
            _ = try await app.place.place(draft, photo: photo, clientToken: token)
            reset()
            return true
        } catch let e as ApiError {
            // You are here now and may not come back: keep the bird rather than lose the pose (issue #89).
            if let why = e.unavailable, park(app, draft, position, photo, token, why) { return false }
            error = placeErrorMessage(e)
        } catch {
            self.error = uiText(error)
        }
        busy = false
        return false
    }

    private func park(_ app: AppModel, _ d: PlacementDraft, _ at: Position, _ photo: Data, _ token: String, _ why: Unavailable) -> Bool {
        guard let user = app.session.user?.id, app.queue.queuePlacement(userId: user, draft: d, accuracy: at.accuracyM, photo: photo, id: token) else { return false }
        app.sync.scheduleIfPending()
        busy = false
        queued = true
        queuedCause = why
        return true
    }

    func reset() {
        let keep = position
        self.position = keep
        chosen = keep?.point
        placeName = ""
        hint = ""
        description = ""
        isPrivate = false
        photo = nil
        error = nil
        busy = false
        queued = false
    }
}

struct PlaceScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(LocationService.self) private var location
    @State private var model = PlaceModel()

    init() {}

    var body: some View {
        Group {
            if let prefs = app.prefs, !prefs.placementCharterAccepted {
                // The charter blocks the form until accepted, once per account (spec §13).
                CharterView { Task { _ = try? await app.prefsRepo.acceptPlacementCharter() } }
            } else if model.queued {
                PlaceQueued(serverDown: model.queuedCause == .serverDown) {
                    model.reset()
                    app.tab = .map
                }
            } else {
                form
            }
        }
        .background(Zine.paper)
        .navigationTitle(L("place_title"))
        .task {
            location.requestPermission()
            if model.position == nil { await model.locate(location) }
            await app.refreshMap()
        }
        .onChange(of: location.permitted) { _, ok in if ok { Task { await model.locate(location) } } }
    }

    private var form: some View {
        @Bindable var model = model
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    LucideIcon("crosshair", size: 16)
                    Text(positionStatus(model.position).text).font(.zBody)
                }
                .foregroundStyle(Zine.muted)
                if !location.permitted {
                    LinkButton(title: L("hunt_allow_location"), font: .zBody) {
                        if location.denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } else { location.requestPermission() }
                    }
                }

                if let pos = model.position, let chosen = model.chosen {
                    PlacementMapCard(styleURL: MapStyle.of(app.prefs?.mapStyle).url, center: pos.point, initial: chosen, nearby: app.stickers ?? []) {
                        model.chosen = $0
                    }
                    let adjusted = adjustedM(pos.point, chosen)
                    HelpLine(icon: "move", text: adjusted > 0 ? L("place_adjusted", adjusted) : L("place_adjust"))
                }

                HStack(alignment: .bottom, spacing: 10) {
                    OpTextField(label: L("place_name"), text: $model.placeName, identifier: "place.name")
                    OpButton(title: model.geoBusy ? "…" : L("place_auto"), icon: "wand_sparkles", variant: .secondary) {
                        Task { await model.fillAddress(app) }
                    }
                    .disabled(model.chosen == nil || model.geoBusy)
                    .accessibilityLabel(L("place_auto_description"))
                }
                HelpLine(icon: nil, text: L("place_name_help"))
                OpTextField(label: L("place_hint"), text: $model.hint)
                MultilineField(label: L("place_description"), text: $model.description, maxLength: 2000)
                PrivateToggle(isOn: $model.isPrivate)

                Text(L("place_photo")).font(.zTitle).foregroundStyle(Zine.ink)
                PhotoInput(photo: model.photo) { model.setPhoto($0) }
                HelpLine(icon: "eye", text: L("place_photo_visibility"))

                if let e = model.error { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }
                OpButton(title: L(model.busy ? "place_busy" : "place_submit"), icon: "map_pin", fullWidth: true) {
                    Task {
                        if await model.submit(app) {
                            app.tab = .map
                            await app.refreshMap(force: true)
                        }
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("place.submit")

                PressRow(title: L("place_order"), icon: "package") { app.push(.order, on: .profile) }
                    .padding(.top, 8)
            }
            .padding(16)
            .padding(.trailing, Zine.pressOffset)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A small muted line, with an optional icon.
struct HelpLine: View {
    let icon: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let icon { LucideIcon(icon, size: 14).padding(.top, 2) }
            Text(text).font(.zBodySmall)
        }
        .foregroundStyle(Zine.muted)
    }
}

/// « Propriété privée », a native switch with its help line.
struct PrivateToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 10) {
                LucideIcon("house", size: 18).foregroundStyle(Zine.privateInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("place_private")).font(.syne(16, 500)).foregroundStyle(Zine.ink)
                    Text(L("place_private_help")).font(.zBodySmall).foregroundStyle(Zine.muted)
                }
            }
        }
        .tint(Zine.pink)
        .accessibilityIdentifier("place.private")
    }
}

/// The bird is parked on the device: what happens next, and back to the map.
struct PlaceQueued: View {
    var serverDown = false
    let onBackToMap: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Mascotte(.search).frame(width: 160, height: 160)
                Text(L("catch_queued_title")).font(.zHeadline).foregroundStyle(Zine.ink)
                Text(L(serverDown ? "place_queued_body_server" : "place_queued_body")).font(.zBodyLarge).foregroundStyle(Zine.ink).multilineTextAlignment(.center)
                Text(L("place_queued_note")).font(.zBody).foregroundStyle(Zine.muted).multilineTextAlignment(.center)
                OpButton(title: L("place_back_to_map"), fullWidth: true, action: onBackToMap)
            }
            .padding(24)
            .padding(.top, 24)
        }
    }
}

/// The placement charter: three rules, then « Je m'engage » (spec §13).
struct CharterView: View {
    let onAccept: () -> Void
    @State private var page = 0
    @Environment(\.openURL) private var openURL

    private let rules: [(MascottePose, String, String)] = [
        (.cartoon, "charter_1_title", "charter_1_body"),
        (.place, "charter_2_title", "charter_2_body"),
        (.search, "charter_3_title", "charter_3_body"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            AuthKicker(text: L("legal_charter"))
                .padding(.top, 12)
            TabView(selection: $page) {
                ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                    ScrollView {
                        VStack(spacing: 14) {
                            Mascotte(rule.0).frame(width: 150, height: 150)
                            Text(L(rule.1)).font(.zTitleLarge).foregroundStyle(Zine.ink).multilineTextAlignment(.center)
                            Text(L(rule.2)).font(.zBodyLarge).foregroundStyle(Zine.muted).multilineTextAlignment(.center)
                        }
                        .padding(24)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            VStack(spacing: 4) {
                if page < rules.count - 1 {
                    OpButton(title: L("common_next"), fullWidth: true) { withAnimation { page += 1 } }
                } else {
                    OpButton(title: L("charter_accept"), fullWidth: true, action: onAccept)
                        .accessibilityIdentifier("charter.accept")
                }
                LinkButton(title: L("charter_read_full"), font: .zBody) { openURL(LegalDoc.charter.url) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}
