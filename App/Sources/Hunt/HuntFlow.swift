import SwiftUI
import Observation
import OiseauCore

// Finding a bird and reporting one missing (Android: ui/find/HuntViewModel.kt,
// HuntSheets.kt, CatchOverlay.kt). The server decides (proximity is checked in SQL);
// with no network or no server the find or report is kept on the device (issue #89).

enum HuntKind { case find, report }

@MainActor
@Observable
final class HuntModel: Identifiable {
    let kind: HuntKind
    let sticker: MapSticker
    private(set) var position: Position?
    private(set) var photo: Data?
    var note = "" { didSet { if note.count > reportNoteMax { note = String(note.prefix(reportNoteMax)) } } }
    private(set) var busy = false
    private(set) var error: UiText?
    /// Accepted, or parked on the device: the success screen is up.
    private(set) var done = false
    private(set) var queued = false
    private(set) var queuedCause: Unavailable = .noNetwork

    nonisolated var id: String { sticker.id }

    init(kind: HuntKind, sticker: MapSticker, position: Position?) {
        self.kind = kind
        self.sticker = sticker
        self.position = position
    }

    var canSubmit: Bool { !busy && !done && position != nil && photo != nil }

    func locate(_ location: LocationService) async {
        let p = await location.current(maxAge: 60, timeout: 15)
        if let p {
            position = p
            if error == .of("hunt_no_position") { error = nil }
        } else if position == nil {
            error = .of("hunt_no_position")
        }
    }

    func setPhoto(_ data: Data?) {
        if let data { photo = data; error = nil } else { error = .of("hunt_bad_photo") }
    }

    func submit(_ app: AppModel) async {
        guard let position, let photo else {
            error = .of("hunt_missing")
            return
        }
        guard canSubmit else { return }
        busy = true
        error = nil
        // Known offline: don't spend a timeout on a request that cannot leave the device.
        if app.reach == .noNetwork, park(app, position, photo, .noNetwork) { return }
        do {
            switch kind {
            case .find: _ = try await app.hunt.find(stickerId: sticker.id, at: position, photo: photo)
            case .report: _ = try await app.hunt.report(stickerId: sticker.id, at: position, photo: photo, note: note)
            }
            busy = false
            done = true
            await app.refreshMap(force: true)
        } catch let e as ApiError {
            // No usable answer: the player is here now and the photo can't be retaken
            // later, so keep it (a replay is safe: one find / one report per player).
            if let why = e.unavailable, park(app, position, photo, why) { return }
            // The button comes back after every refusal: a too_far is exactly when
            // the player walks closer and tries again.
            self.error = kind == .find ? findErrorMessage(e) : reportErrorMessage(e)
            busy = false
        } catch {
            self.error = uiText(error)
            busy = false
        }
    }

    private func park(_ app: AppModel, _ at: Position, _ photo: Data, _ why: Unavailable) -> Bool {
        guard let user = app.session.user?.id else { return false }
        let stored = switch kind {
        case .find: app.queue.queueFind(userId: user, stickerId: sticker.id, placeName: sticker.placeName, at: at, photo: photo)
        case .report: app.queue.queueReport(userId: user, stickerId: sticker.id, placeName: sticker.placeName, at: at, photo: photo, note: note)
        }
        guard stored else { return false }
        app.sync.scheduleIfPending()
        busy = false
        done = true
        queued = true
        queuedCause = why
        return true
    }
}

/// The find or report sheet: position, photo, (note), submit — then the catch screen.
struct HuntSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(LocationService.self) private var location
    @Bindable var model: HuntModel
    let onClose: () -> Void

    init(model: HuntModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    var body: some View {
        if model.done {
            CatchView(model: model, onClose: onClose)
        } else {
            form
        }
    }

    private var form: some View {
        let find = model.kind == .find
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L(find ? "hunt_find_title" : "hunt_report_title")).font(.zTitleLarge).foregroundStyle(Zine.ink)
                    Spacer()
                    Button(action: onClose) { LucideIcon("x", size: 20).foregroundStyle(Zine.ink).frame(width: 44, height: 44) }
                        .accessibilityLabel(L("common_close"))
                }
                Text(model.sticker.placeName).font(.zTitle).foregroundStyle(Zine.muted)
                HStack(spacing: 8) {
                    LucideIcon("crosshair", size: 16)
                    Text(positionStatus(model.position).text).font(.zBody)
                }
                .foregroundStyle(Zine.muted)
                if location.denied || !location.permitted {
                    LinkButton(title: L("hunt_allow_location"), font: .zBody) {
                        if location.denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } else { location.requestPermission() }
                    }
                }
                Text(L(find ? "hunt_find_photo" : "hunt_report_photo")).font(.zTitle).foregroundStyle(Zine.ink)
                PhotoInput(photo: model.photo) { model.setPhoto($0) }
                if !find {
                    MultilineField(label: L("hunt_note"), text: $model.note, maxLength: reportNoteMax, placeholder: L("hunt_note_placeholder"))
                    Text(L("hunt_note_count", model.note.count, reportNoteMax)).font(.zBodySmall).foregroundStyle(Zine.muted)
                }
                Text(L(find ? "hunt_find_visibility" : "hunt_report_visibility")).font(.zBodySmall).foregroundStyle(Zine.muted)
                if let e = model.error { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }
                OpButton(
                    title: L(model.busy ? (find ? "hunt_find_busy" : "hunt_report_busy") : (find ? "hunt_find_submit" : "hunt_report_submit")),
                    fullWidth: true
                ) { Task { await model.submit(app) } }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("hunt.submit")
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await model.locate(location) }
    }
}

/// « Attrapé ! », « Signalé ! », or « Gardé au chaud » (yellow: one of the fun moments).
private struct CatchView: View {
    let model: HuntModel
    let onClose: () -> Void
    @State private var popped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (title, body, pose): (String, String, MascottePose) = {
            switch (model.kind, model.queued, model.queuedCause) {
            case (.find, false, _): return ("catch_caught_title", "catch_caught_body", .celebrate)
            case (.report, false, _): return ("catch_reported_title", "catch_reported_body", .celebrate)
            case (.find, true, .noNetwork): return ("catch_queued_title", "catch_queued_body", .search)
            case (.find, true, .serverDown): return ("catch_queued_title", "catch_queued_body_server", .search)
            case (.report, true, .noNetwork): return ("catch_queued_title", "report_queued_body", .search)
            case (.report, true, .serverDown): return ("catch_queued_title", "report_queued_body_server", .search)
            }
        }()
        VStack(spacing: 16) {
            Spacer()
            Group {
                if let data = model.photo, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Mascotte(.photo)
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: Zine.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: Zine.radiusLarge).stroke(Zine.ink, lineWidth: 3))
            .rotationEffect(.degrees(popped ? -3 : -12))
            .scaleEffect(popped ? 1 : 0.3)
            Text(L(title)).font(.zDisplay).foregroundStyle(model.queued ? Zine.archivedInk : Zine.found)
            Text(model.sticker.placeName).font(.zTitleLarge).foregroundStyle(Zine.ink).multilineTextAlignment(.center)
            Text(L(body)).font(.zBodyLarge).foregroundStyle(Zine.muted).multilineTextAlignment(.center)
            Mascotte(pose).frame(width: 140, height: 140).scaleEffect(popped ? 1 : 0.5)
            Spacer()
            OpButton(title: L("common_close"), fullWidth: true, action: onClose)
                .accessibilityIdentifier("catch.close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadialGradient(colors: [Zine.yellow, Zine.paper], center: .center, startRadius: 10, endRadius: 520).ignoresSafeArea())
        .sensoryFeedback(.success, trigger: popped)
        .onAppear {
            if reduceMotion { popped = true } else { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { popped = true } }
        }
    }
}
