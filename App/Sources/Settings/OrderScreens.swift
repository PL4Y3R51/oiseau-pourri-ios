import SwiftUI
import Observation
import OiseauCore

// « Commander des oiseaux pourris » (Android: ui/order/Orders.kt). One order in progress
// at a time; the team handles it by hand, the server mails both sides.

extension DeliveryMode {
    var labelKey: String {
        switch self {
        case .hand: return "order_mode_hand"
        case .other: return "order_mode_other"
        default: return "order_mode_post"
        }
    }
}

extension StickerRequestStatus {
    var labelKey: String {
        switch self {
        case .sent: return "order_status_sent"
        case .declined: return "order_status_declined"
        case .cancelled: return "order_status_cancelled"
        default: return "order_status_pending"
        }
    }
}

@MainActor
@Observable
final class OrderModel {
    var draft = OrderDraft()
    private(set) var loading = true
    /// The order in progress, if any: it replaces the form.
    private(set) var current: StickerRequest?
    private(set) var justSent = false
    private(set) var busy = false
    private(set) var error: UiText?

    var pending: StickerRequest? { current?.status == .pending ? current : nil }

    func load(_ app: AppModel) async {
        // The last known order when there is no server (issue #89).
        let mine = try? await app.cachedOptional("order-mine") { try await app.api.get("/api/sticker-requests/mine", as: StickerRequest.self) }
        if let mine { current = mine }
        loading = false
    }

    func submit(_ app: AppModel) async {
        guard !busy else { return }
        let body: CreateStickerRequestBody
        switch orderBody(draft) {
        case .failure(let invalid):
            error = invalid.reason
            return
        case .success(let b):
            body = b
        }
        busy = true
        error = nil
        do {
            current = try await app.api.post("/api/sticker-requests", body, as: StickerRequest.self)
            justSent = true
            draft = OrderDraft()
        } catch let e as ApiError {
            // An order is a request to a person (an e-mail goes out): it needs the server now.
            error = e.isUnavailable ? e.toUiText() : e.code == "already_pending" ? .of("order_error_pending") : .of("order_error_send")
            if e.code == "already_pending" { await load(app) }
        } catch {
            self.error = .of("order_error_send")
        }
        busy = false
    }

    func cancel(_ app: AppModel) async {
        guard let p = pending else { return }
        busy = true
        error = nil
        do {
            current = try await app.api.post("/api/sticker-requests/\(p.id)/cancel", EmptyBody(), as: StickerRequest.self)
            justSent = false
        } catch {
            // Perhaps handled in the meantime: say so and show what it is now.
            self.error = .of("order_error_cancel")
            await load(app)
        }
        busy = false
    }
}

struct OrderScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = OrderModel()

    init() {}

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.loading {
                    Text(L("common_loading")).font(.zBody).foregroundStyle(Zine.muted)
                } else if let pending = model.pending {
                    if model.justSent {
                        HStack(spacing: 8) {
                            LucideIcon("circle_check", size: 18)
                            Text(L("order_sent")).font(.zBody)
                        }
                        .foregroundStyle(Zine.found)
                    }
                    OrderSummary(request: pending, busy: model.busy) { Task { await model.cancel(app) } }
                    if let e = model.error { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }
                    historyLink
                } else {
                    let d = model.draft
                    Text(L("order_intro")).font(.zBody).foregroundStyle(Zine.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("order_delivery")).font(.zBody).foregroundStyle(Zine.muted)
                        Picker("", selection: $model.draft.mode) {
                            ForEach([DeliveryMode.post, .hand, .other], id: \.self) { Text(L($0.labelKey)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    OpTextField(label: L("order_quantity", orderQuantityMax), text: Binding(
                        get: { model.draft.quantity },
                        set: { model.draft.quantity = String($0.filter(\.isNumber).prefix(3)) }
                    ))
                    .keyboardType(.numberPad)
                    if d.mode != .hand {
                        MultilineField(label: L(d.mode == .post ? "order_address_post" : "order_address_other"), text: $model.draft.address, maxLength: orderAddressMax)
                    }
                    MultilineField(
                        label: L(d.mode == .hand ? "order_where" : "order_message"),
                        text: $model.draft.message,
                        maxLength: orderMessageMax,
                        placeholder: d.mode == .hand ? L("order_where_placeholder") : nil
                    )
                    if d.mode == .post {
                        Text(L("order_address_privacy")).font(.zBodySmall).foregroundStyle(Zine.muted)
                    }
                    if let e = model.error { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }
                    OpButton(title: L("order_submit"), fullWidth: true) { Task { await model.submit(app) } }
                        .disabled(model.busy)
                    historyLink
                }
            }
            .padding(16)
            .padding(.trailing, Zine.pressOffset)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Zine.paper)
        .navigationTitle(L("order_title"))
        .task { await model.load(app) }
    }

    private var historyLink: some View {
        NavigationLink(value: Route.orderHistory) {
            HStack(spacing: 12) {
                LucideIcon("history", size: 20)
                Text(L("order_history")).font(.zTitle)
                Spacer()
                LucideIcon("chevron_right", size: 18).foregroundStyle(Zine.muted)
            }
            .foregroundStyle(Zine.ink)
            .padding(14)
            .background(Zine.panel)
        }
        .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
    }
}

/// A multi-line text box with its label above, capped at [maxLength].
struct MultilineField: View {
    let label: String
    @Binding var text: String
    var maxLength: Int
    var placeholder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.zBody).foregroundStyle(Zine.muted)
            TextField(placeholder ?? "", text: Binding(get: { text }, set: { text = String($0.prefix(maxLength)) }), axis: .vertical)
                .lineLimit(3...8)
                .font(.zBodyLarge)
                .padding(14)
                .background(Zine.panel, in: RoundedRectangle(cornerRadius: Zine.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Zine.radiusSmall).stroke(Zine.ink, lineWidth: 1))
                .accessibilityLabel(label)
        }
    }
}

/// One order: quantity, delivery, status and date; the cancel button while pending.
struct OrderSummary: View {
    let request: StickerRequest
    var busy = false
    var onCancel: (() -> Void)?

    var body: some View {
        let r = request
        VStack(alignment: .leading, spacing: 6) {
            Text(L("order_quantity_label", r.quantity)).font(.syne(16, 700)) + Text(" · " + L(r.deliveryMode.labelKey)).font(.zBodyLarge)
            Text(L("order_status_line", L(r.status.labelKey), dayMonth(r.createdAt))).font(.zBodySmall).foregroundStyle(Zine.muted)
            if let a = r.address { Text(a).font(.zBody) }
            if let m = r.message { Text(m).font(.zBody) }
            if let onCancel {
                OpButton(title: L("order_cancel"), variant: .danger, fullWidth: true, action: onCancel).disabled(busy)
            }
        }
        .foregroundStyle(Zine.ink)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zine.panel, in: RoundedRectangle(cornerRadius: Zine.radiusMedium))
    }

    private func dayMonth(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        return d.formatted(Date.FormatStyle().day().month(.wide).locale(appLocale))
    }
}

/// Past orders, a page at a time (« Voir plus »).
struct OrderHistoryScreen: View {
    @Environment(AppModel.self) private var app
    @State private var requests: [StickerRequest] = []
    @State private var total = 0
    @State private var loading = true
    @State private var failed = false

    init() {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(requests, id: \.id) { OrderSummary(request: $0) }
                if !loading && !failed && requests.isEmpty { Text(L("order_history_empty")).font(.zBody).foregroundStyle(Zine.muted) }
                if failed { Text(L("order_history_failed")).font(.zBody).foregroundStyle(Zine.error) }
                if loading { Text(L("common_loading")).font(.zBody).foregroundStyle(Zine.muted) }
                if !loading && requests.count < total {
                    OpButton(title: L("order_more"), variant: .secondary, fullWidth: true) { Task { await loadMore() } }
                }
            }
            .padding(16)
        }
        .background(Zine.paper)
        .navigationTitle(L("order_history"))
        .task { if requests.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        let offset = total > 0 ? requests.count : 0
        loading = true
        failed = false
        do {
            let fetch = { () async throws -> StickerRequestHistoryResponse in
                guard let page = try await app.api.get("/api/sticker-requests/history?offset=\(offset)", as: StickerRequestHistoryResponse.self) else {
                    throw ApiError(status: 200, code: "bad_response")
                }
                return page
            }
            // The first page is kept for an offline look (issue #89); the next ones need the server.
            let page = offset == 0 ? try await app.cached("order-history", fetch).value : try await fetch()
            requests = offset == 0 ? page.requests : requests + page.requests
            total = page.total
        } catch {
            failed = true
        }
        loading = false
    }
}

// MARK: - The order's rules (pure; move to OiseauCore with tests)

/// Mirrors of the shared limits (packages/shared STICKER_REQUEST_*).
let orderQuantityMax = 100
let orderAddressMax = 500
let orderMessageMax = 1000

struct OrderDraft: Equatable {
    var mode: DeliveryMode = .post
    var quantity = "5"
    var address = ""
    var message = ""
}

struct OrderInvalid: Error {
    let reason: UiText
}

/// The order body, or why it can't go: an address unless handed over, a meeting place when it is.
func orderBody(_ d: OrderDraft) -> Result<CreateStickerRequestBody, OrderInvalid> {
    guard let qty = Int(d.quantity.trimmingCharacters(in: .whitespaces)), (1...orderQuantityMax).contains(qty) else {
        return .failure(OrderInvalid(reason: .of("order_error_quantity", String(orderQuantityMax))))
    }
    let address = d.address.trimmingCharacters(in: .whitespacesAndNewlines)
    if d.mode != .hand && address.isEmpty { return .failure(OrderInvalid(reason: .of("order_error_address"))) }
    let message = d.message.trimmingCharacters(in: .whitespacesAndNewlines)
    if d.mode == .hand && message.isEmpty { return .failure(OrderInvalid(reason: .of("order_error_where"))) }
    return .success(CreateStickerRequestBody(
        deliveryMode: CreateStickerRequestBodyDeliveryMode(rawValue: d.mode.rawValue) ?? .post,
        quantity: qty,
        address: d.mode == .hand ? nil : address,
        message: message.isEmpty ? nil : message
    ))
}
