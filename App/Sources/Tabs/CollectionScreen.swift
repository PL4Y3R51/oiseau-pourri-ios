import SwiftUI
import Observation
import OiseauCore

// The Collection tab (Android: ui/collection/*). Found birds and the birds I hid, sorted,
// filtered and grouped; a bird opens in a sheet. On iOS the controls are toolbar menus.

/// The detail open over the list.
enum CollectionDetail: Identifiable {
    case found(CollectionItem)
    case placed(String)

    var id: String {
        switch self {
        case .found(let i): return "f-\(i.stickerId)"
        case .placed(let id): return "p-\(id)"
        }
    }
}

@MainActor
@Observable
final class CollectionModel {
    private(set) var loading = true
    private(set) var error: UiText?
    private(set) var found: [CollectionItem] = []
    private(set) var hidden: [MyPlacedSticker] = []
    private(set) var staleSince: Date?
    var tab: CollectionTab = .found {
        didSet {
            sort = sortForTab(sort, tab)
            prune()
            UserDefaults.standard.set(tab.rawValue, forKey: "collection.tab")
        }
    }
    var sort = CollectionSort()
    var grouping: Grouping = .none
    var filters = CollectionFilters()
    var detail: CollectionDetail?

    // The open bird of mine: its finders and reports, loaded after opening.
    private(set) var finders: [StickerFinder]?
    private(set) var reports: [StickerReport]?
    /// Finders and reports couldn't be asked (no network, no server): not "nobody" (issue #89).
    private(set) var extrasUnavailable = false
    private(set) var busy = false
    var detailError: UiText?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "collection.tab"), let t = CollectionTab(rawValue: saved) { tab = t }
    }

    func load(_ app: AppModel) async {
        do {
            let col = try await app.collection.load()
            found = col.found
            // Changes still parked on the device show as made (issue #89).
            hidden = col.hidden.withPendingPlaced(app.queue.items, userId: app.session.user?.id)
            staleSince = col.staleSince
            error = nil
            prune()
            consumeFocus(app)
        } catch {
            self.error = uiText(error)
        }
        loading = false
    }

    private func prune() {
        let hasArchived = tab == .hidden ? hidden.contains { $0.status == .archived } : found.contains { $0.status == .archived }
        filters = pruneFilters(filters, tab: tab, hasArchived: hasArchived, reportedCount: reportedCount, countries: countryCodes(tab, found: found, hidden: hidden))
    }

    var reportedCount: Int { hidden.filter(\.hasOpenReport).count }

    /// « Ouvrir dans ma collection » from the map: once the lists are in.
    private func consumeFocus(_ app: AppModel) {
        guard let focus = app.collectionFocus else { return }
        app.collectionFocus = nil
        if focus.hidden, hidden.contains(where: { $0.id == focus.id }) {
            tab = .hidden
            open(placed: focus.id, app)
        } else if let item = found.first(where: { $0.stickerId == focus.id }) {
            tab = .found
            detail = .found(item)
        }
    }

    func placed(_ id: String) -> MyPlacedSticker? { hidden.first { $0.id == id } }

    func open(placed id: String, _ app: AppModel) {
        detail = .placed(id)
        finders = nil
        reports = nil
        extrasUnavailable = false
        detailError = nil
        Task {
            do { finders = try await app.collection.finders(id) } catch {
                extrasUnavailable = extrasUnavailable || error.isUnavailable
                finders = error.isUnavailable ? nil : []
            }
        }
        Task {
            do { reports = try await app.collection.reports(id) } catch {
                extrasUnavailable = extrasUnavailable || error.isUnavailable
                reports = error.isUnavailable ? nil : []
            }
        }
    }

    private func replace(_ id: String, _ change: (inout MyPlacedSticker) -> Void) {
        if let i = hidden.firstIndex(where: { $0.id == id }) { change(&hidden[i]) }
    }

    func refreshHidden(_ app: AppModel) async {
        if let fresh = try? await app.collection.hidden() {
            hidden = fresh.withPendingPlaced(app.queue.items, userId: app.session.user?.id)
            prune()
        }
    }

    /// Optimistic, reverted on refusal.
    func togglePrivate(_ s: MyPlacedSticker, _ app: AppModel) async {
        let next = !s.isPrivate
        replace(s.id) { $0.isPrivate = next }
        detailError = nil
        do {
            if try await app.map.setPrivate(s.id, next) == .now { await refreshHidden(app) }
        } catch {
            replace(s.id) { $0.isPrivate = !next }
            detailError = error.toUiText()
        }
    }

    func toggleArchive(_ s: MyPlacedSticker, _ app: AppModel) async {
        let archive = s.status != .archived
        busy = true
        detailError = nil
        do {
            switch try await app.map.setArchived(s.id, archive) {
            case .now: await refreshHidden(app)
            // Parked (issue #89): shown as done; the server has it once it answers.
            case .later: replace(s.id) { $0.status = archive ? .archived : .active }; prune()
            }
        } catch {
            detailError = error.toUiText()
        }
        busy = false
    }

    func delete(_ s: MyPlacedSticker, _ app: AppModel) async {
        busy = true
        detailError = nil
        do {
            _ = try await app.map.delete(s.id)
            detail = nil
            hidden.removeAll { $0.id == s.id }
            prune()
        } catch {
            detailError = error.toUiText()
        }
        busy = false
    }

    /// Confirm the bird is gone (archives it, rewards the reporter) or say it is still there.
    func decide(_ report: StickerReport, accepted: Bool, _ app: AppModel) async {
        do {
            try await app.collection.decideReport(report.id, accepted: accepted)
            reports?.removeAll { $0.id == report.id }
            await refreshHidden(app)
        } catch {
            detailError = error.toUiText()
        }
    }
}

struct CollectionScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = CollectionModel()

    init() {}

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $model.tab) {
                    Text(L("collection_tab_found", model.found.count)).tag(CollectionTab.found)
                    Text(L("collection_tab_hidden", model.hidden.count)).tag(CollectionTab.hidden)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("collection.tab")

                let stats = collectionStats(model.tab, found: model.found, hidden: model.hidden)
                HStack(spacing: 8) {
                    StatChip(text: L("collection_stat_finds", stats.finds))
                    if stats.countries > 0 { StatChip(text: L("collection_stat_countries", stats.countries)) }
                }

                if let since = model.staleSince { StaleBanner(since: since) }
                if let e = model.error { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }

                if model.loading {
                    LoadingView().frame(height: 240)
                } else if model.tab == .found {
                    foundGrid
                } else {
                    hiddenGrid
                }
            }
            .padding(16)
            .padding(.trailing, Zine.pressOffset)
        }
        .background(Zine.paper)
        .navigationTitle(L("collection_title"))
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { controls } }
        .refreshable { await model.load(app) }
        .task { await model.load(app) }
        .onChange(of: app.collectionFocus?.id) { _, id in if id != nil { Task { await model.load(app) } } }
        .onChange(of: app.collectionSheetCloseRequest) { _, _ in model.detail = nil }
        .sheet(item: $model.detail) { detail in
            Group {
                switch detail {
                case .found(let item): FoundDetail(item: item)
                case .placed(let id):
                    if let s = model.placed(id) { PlacedDetail(sticker: s, model: model) }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Zine.panel)
        }
    }

    // MARK: Grids

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 128), spacing: 10)] }

    private func countryLabel(_ code: String?) -> String {
        countryName(code, locale: Locale.current) ?? L("collection_unknown_country")
    }

    @ViewBuilder private var foundGrid: some View {
        let items = visibleFound(model.found, model.filters, model.sort)
        if model.found.isEmpty {
            EmptyStateView(text: L("collection_empty_found"), pose: .search)
        } else if items.isEmpty {
            EmptyStateView(text: L("collection_empty_filtered"))
        } else {
            ForEach(sections(items, code: \.countryCode, date: \.foundAt), id: \.key) { section in
                if model.grouping != .none { GroupTitle(text: section.label) }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(section.items, id: \.stickerId) { item in
                        Button { model.detail = .found(item) } label: { FoundCard(item: item) }
                            .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
                    }
                }
            }
        }
    }

    @ViewBuilder private var hiddenGrid: some View {
        let items = visibleHidden(model.hidden, model.filters, model.sort)
        if model.hidden.isEmpty {
            EmptyStateView(text: L("collection_empty_hidden"), pose: .place)
        } else if items.isEmpty {
            EmptyStateView(text: L("collection_empty_filtered"))
        } else {
            // Birds reported missing come first, to check.
            let reported = items.filter(\.hasOpenReport)
            if !reported.isEmpty && model.grouping == .none && !model.filters.reportedOnly {
                GroupTitle(text: L("collection_to_check", reported.count), icon: "flag")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(reported, id: \.id) { hiddenButton($0) }
                }
            }
            let rest = model.grouping == .none && !model.filters.reportedOnly ? items.filter { !$0.hasOpenReport } : items
            ForEach(sections(rest, code: \.countryCode, date: \.placedAt), id: \.key) { section in
                if model.grouping != .none { GroupTitle(text: section.label) }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(section.items, id: \.id) { hiddenButton($0) }
                }
            }
        }
    }

    private func hiddenButton(_ s: MyPlacedSticker) -> some View {
        Button { model.open(placed: s.id, app) } label: { HiddenCard(sticker: s) }
            .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
    }

    private func sections<T>(_ items: [T], code: KeyPath<T, String?>, date: KeyPath<T, String>) -> [CollectionSection<T>] {
        switch model.grouping {
        case .none: return [CollectionSection(key: "all", label: "", items: items)]
        case .country:
            return groupSections(items, key: { $0[keyPath: code] ?? unknownCountry }, label: { countryLabel($0[keyPath: code]) })
        case .month:
            return groupSections(items, key: { String($0[keyPath: date].prefix(7)) }, label: { monthLabel($0[keyPath: date], locale: Locale.current) })
        }
    }

    // MARK: Controls (toolbar menus)

    @ViewBuilder private var controls: some View {
        @Bindable var model = model
        Menu {
            Picker(L("collection_sort_by"), selection: $model.sort.key) {
                ForEach(sortKeysFor(model.tab), id: \.self) { Text(L($0.labelKey)).tag($0) }
            }
            Picker(L("collection_order"), selection: $model.sort.descending) {
                Text(L(model.sort.key.descKey)).tag(true)
                Text(L(model.sort.key.ascKey)).tag(false)
            }
            if !model.sort.isDefault {
                Button(L("map_filters_reset")) { model.sort = CollectionSort() }
            }
        } label: {
            ControlIcon(icon: "arrow_down_up", active: !model.sort.isDefault)
        }
        .accessibilityLabel(L("collection_sort_a11y"))

        let available = filterAvailability(
            model.tab,
            hasArchived: model.tab == .hidden ? model.hidden.contains { $0.status == .archived } : model.found.contains { $0.status == .archived },
            reportedCount: model.reportedCount,
            countryCount: countryCodes(model.tab, found: model.found, hidden: model.hidden).count
        )
        if available.any {
            Menu {
                if available.status {
                    Section(L("collection_status")) {
                        ForEach([StickerStatus.active, .archived], id: \.self) { st in
                            Toggle(L(st == .active ? "collection_status_active" : "collection_status_archived"), isOn: Binding(
                                get: { model.filters.statuses.contains(st) },
                                set: { on in if on { model.filters.statuses.insert(st) } else { model.filters.statuses.remove(st) } }
                            ))
                        }
                    }
                }
                if available.reported {
                    Section(L("collection_reports")) {
                        Toggle(L("collection_to_check", model.reportedCount), isOn: $model.filters.reportedOnly)
                    }
                }
                if available.countries {
                    Section(L("collection_countries")) {
                        ForEach(countryCodes(model.tab, found: model.found, hidden: model.hidden).sorted(), id: \.self) { code in
                            Toggle(countryLabel(code == unknownCountry ? nil : code), isOn: Binding(
                                get: { model.filters.countries.contains(code) },
                                set: { on in if on { model.filters.countries.insert(code) } else { model.filters.countries.remove(code) } }
                            ))
                        }
                    }
                }
                if model.filters.active {
                    Button(L("map_filters_reset")) { model.filters = CollectionFilters() }
                }
            } label: {
                ControlIcon(icon: "funnel", active: model.filters.active)
            }
            .accessibilityLabel(L("collection_filters_a11y"))
        }

        Menu {
            Picker(L("collection_group_by"), selection: $model.grouping) {
                ForEach(Grouping.allCases, id: \.self) { Text(L($0.labelKey)).tag($0) }
            }
        } label: {
            ControlIcon(icon: "group", active: model.grouping != .none)
        }
        .accessibilityLabel(L("collection_group_a11y"))
    }
}

/// A toolbar control's icon, with a pink dot while it is off its default.
private struct ControlIcon: View {
    let icon: String
    let active: Bool

    var body: some View {
        LucideIcon(icon, size: 20)
            .overlay(alignment: .topTrailing) {
                if active { Circle().fill(Zine.pink).overlay(Circle().stroke(Zine.ink, lineWidth: 1)).frame(width: 8, height: 8).offset(x: 4, y: -3) }
            }
    }
}

private struct StatChip: View {
    let text: String
    var body: some View {
        Text(text).font(.syne(12.5, 700)).foregroundStyle(Zine.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Zine.yellow, in: Capsule())
            .overlay(Capsule().stroke(Zine.ink, lineWidth: 1))
    }
}

private struct GroupTitle: View {
    let text: String
    var icon: String?
    var body: some View {
        HStack(spacing: 6) {
            if let icon { LucideIcon(icon, size: 16) }
            Text(text).font(.zTitle)
        }
        .foregroundStyle(Zine.ink)
        .padding(.top, 6)
    }
}

/// A card: the picture, a tag in a corner, two lines under it.
private struct CardFrame<Image: View, Meta: View>: View {
    @ViewBuilder let image: () -> Image
    var tag: (text: String, color: Color, icon: String?)?
    @ViewBuilder let meta: () -> Meta

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { image() }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if let tag {
                        HStack(spacing: 3) {
                            if let icon = tag.icon { LucideIcon(icon, size: 11) }
                            Text(tag.text).font(.zLabelSmall)
                        }
                        .foregroundStyle(Zine.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(tag.color, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Zine.ink, lineWidth: 1))
                        .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) { meta() }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Zine.panel)
    }
}

private struct FoundCard: View {
    let item: CollectionItem
    var body: some View {
        CardFrame(
            image: { AsyncPhoto(photoId: item.findPhotoId, thumb: true) },
            tag: item.status == .archived ? (L("collection_card_archived"), Color(Zine.pin(.archived)), nil) : nil
        ) {
            Text(item.placeName).font(.syne(12.5, 700)).foregroundStyle(Zine.ink).lineLimit(2).multilineTextAlignment(.leading)
            Text(shortDate(item.foundAt)).font(.zBodySmall).foregroundStyle(Zine.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HiddenCard: View {
    let sticker: MyPlacedSticker
    var body: some View {
        let s = sticker
        CardFrame(
            image: {
                if let id = s.placementPhotoId { AsyncPhoto(photoId: id, thumb: true) } else { Mascotte(.photo) }
            },
            tag: s.hasOpenReport ? (L("collection_card_reported"), Zine.pink, "flag")
                : s.status == .archived ? (L("collection_card_archived"), Color(Zine.pin(.archived)), nil) : nil
        ) {
            HStack(spacing: 3) {
                if s.isPrivate { LucideIcon("house", size: 11) }
                Text(s.placeName).font(.syne(12.5, 700)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .foregroundStyle(Zine.ink)
            Text(L("collection_card_placed", shortDate(s.placedAt))).font(.zBodySmall).foregroundStyle(Zine.muted)
            Text(L("collection_stat_finds", s.findCount)).font(.zBodySmall).foregroundStyle(Zine.found)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Details

private struct FoundDetail: View {
    @Environment(AppModel.self) private var app
    let item: CollectionItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DetailTitle(text: item.placeName)
                Sub(icon: "calendar", text: L("detail_found_on", longDate(item.foundAt) ?? ""))
                PlacerLink(userId: item.placedById, name: item.placedByName)
                if item.status == .archived { Status(icon: "archive", text: L("detail_found_archived"), color: Zine.archivedInk) }
                Figure(photoId: item.findPhotoId, caption: L("detail_your_trophy"))
                if let id = item.placementPhotoId { Figure(photoId: id, caption: L("detail_their_pose", item.placedByName)) }
                if let d = item.description { Text(d).font(.zBody).foregroundStyle(Zine.ink) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
        }
    }
}

private struct PlacedDetail: View {
    @Environment(AppModel.self) private var app
    let sticker: MyPlacedSticker
    let model: CollectionModel
    @State private var confirmDelete = false
    @State private var editing = false

    var body: some View {
        let s = sticker
        let archived = s.status == .archived
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DetailTitle(text: s.placeName)
                Sub(icon: "calendar", text: L("detail_placed_on", longDate(s.placedAt) ?? ""))
                if archived { Status(icon: "archive", text: L("detail_placed_archived"), color: Zine.archivedInk) }
                if let id = s.placementPhotoId {
                    Figure(photoId: id, caption: L("sheet_my_placement"))
                } else {
                    Text(L("detail_no_pose_photo")).font(.zBodySmall).foregroundStyle(Zine.muted)
                }
                if let d = s.description { Text(d).font(.zBody).foregroundStyle(Zine.ink) }
                if let h = s.hint { HStack(alignment: .top, spacing: 8) { LucideIcon("lightbulb", size: 16).foregroundStyle(Zine.wishInk); Text(h).font(.zBody) } }
                if let r = s.discoveryRadiusM { Sub(icon: "target", text: L("detail_radius", r)) }

                let open = (model.reports ?? []).filter { $0.status == .open }
                if !open.isEmpty {
                    SectionHead(icon: "flag", text: L("detail_reported", open.count))
                    ForEach(open, id: \.id) { r in ReportRow(report: r, model: model) }
                }

                SectionHead(icon: "users", text: L("detail_finders"))
                if let finders = model.finders {
                    if finders.isEmpty {
                        Text(L("detail_no_finders")).font(.zBody).foregroundStyle(Zine.muted)
                    } else {
                        ForEach(finders, id: \.userId) { FinderRow(finder: $0) }
                    }
                } else {
                    Text(L(model.extrasUnavailable ? "detail_when_online" : "common_loading")).font(.zBody).foregroundStyle(Zine.muted)
                }

                if let e = model.detailError { Text(e.text).font(.zBody).foregroundStyle(Zine.error) }

                Toggle(isOn: Binding(get: { s.isPrivate }, set: { _ in Task { await model.togglePrivate(s, app) } })) {
                    Label { Text(L("sheet_private")).font(.zBody) } icon: { LucideIcon("house", size: 16) }
                }
                .tint(Zine.pink)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    if !archived && editRules(placedAt: parseIsoDate(s.placedAt) ?? .distantPast, hasFinds: s.findCount > 0, now: Date()).fullEdit {
                        OpButton(title: L("common_edit"), icon: "pencil", variant: .secondary, fullWidth: true) { editing = true }
                    }
                    OpButton(title: L(archived ? "menu_unarchive" : "menu_archive"), icon: archived ? "archive_restore" : "archive", variant: .secondary, fullWidth: true) {
                        Task { await model.toggleArchive(s, app) }
                    }
                }
                .disabled(model.busy)
                OpButton(title: L("common_delete"), icon: "trash_2", variant: .danger, fullWidth: true) { confirmDelete = true }
                    .disabled(model.busy)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
        }
        .confirmationDialog(L("common_delete"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("common_delete"), role: .destructive) { Task { await model.delete(s, app) } }
            Button(L("common_cancel"), role: .cancel) {}
        } message: {
            Text((s.findCount > 0 ? L("detail_delete_warning", s.findCount) + " " : "") + L("detail_delete_irreversible"))
        }
        .sheet(isPresented: $editing, onDismiss: { Task { await model.refreshHidden(app) } }) {
            EditStickerView(target: EditTarget(placed: s))
        }
    }
}

private struct ReportRow: View {
    @Environment(AppModel.self) private var app
    let report: StickerReport
    let model: CollectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Avatar(image: report.image, size: 32)
                VStack(alignment: .leading) {
                    Text(report.reportedByName).font(.syne(14, 700))
                    Text(shortDate(report.createdAt)).font(.zBodySmall).foregroundStyle(Zine.muted)
                }
            }
            if let note = report.note { Text(note).font(.zBody) }
            Figure(photoId: report.photoId, caption: L("detail_report_proof", report.reportedByName))
            HStack(spacing: 10) {
                OpButton(title: L("detail_report_confirm"), icon: "check", variant: .secondary, fullWidth: true) {
                    Task { await model.decide(report, accepted: true, app) }
                }
                .accessibilityLabel(L("detail_report_confirm_a11y"))
                OpButton(title: L("detail_report_dismiss"), variant: .secondary, fullWidth: true) {
                    Task { await model.decide(report, accepted: false, app) }
                }
                .accessibilityLabel(L("detail_report_dismiss_a11y"))
            }
        }
        .foregroundStyle(Zine.ink)
        .padding(12)
        .background(Zine.paper, in: RoundedRectangle(cornerRadius: Zine.radiusMedium))
    }
}

private struct FinderRow: View {
    @Environment(AppModel.self) private var app
    let finder: StickerFinder

    var body: some View {
        Button {
            app.collectionDetailDismissed()
            app.push(.profile(userId: finder.userId), on: .collection)
        } label: {
            HStack(spacing: 10) {
                Avatar(image: finder.image, size: 32)
                Text(L("detail_finder_caption", finder.displayName, shortDate(finder.foundAt))).font(.zBody).foregroundStyle(Zine.ink)
                Spacer()
                AsyncPhoto(photoId: finder.findPhotoId, thumb: true).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(L("detail_finder_trophy_a11y", finder.displayName))
            }
        }
        .buttonStyle(.plain)
    }
}

/// The placer's name, leading to their profile (none for the deleted-accounts ghost).
private struct PlacerLink: View {
    @Environment(AppModel.self) private var app
    let userId: String
    let name: String

    var body: some View {
        if userId == deletedUserId {
            Sub(icon: "user_round", text: L("sheet_placed_by", name))
        } else {
            Button {
                app.collectionDetailDismissed()
                app.push(.profile(userId: userId), on: .collection)
            } label: {
                HStack(spacing: 6) {
                    LucideIcon("user_round", size: 14)
                    Text(L("sheet_placed_by", name)).font(.zBody).underline()
                }
                .foregroundStyle(Zine.ink)
            }
            .buttonStyle(.plain)
        }
    }
}

struct DetailTitle: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            LucideIcon("map_pin", size: 20)
            Text(text).font(.zTitleLarge)
        }
        .foregroundStyle(Zine.ink)
        .accessibilityAddTraits(.isHeader)
    }
}

struct Sub: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            LucideIcon(icon, size: 14)
            Text(text).font(.zBody)
        }
        .foregroundStyle(Zine.muted)
    }
}

struct Status: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            LucideIcon(icon, size: 15)
            Text(text).font(.zBody)
        }
        .foregroundStyle(color)
    }
}

private struct SectionHead: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            LucideIcon(icon, size: 16)
            Text(text).font(.zTitle)
        }
        .foregroundStyle(Zine.ink)
        .padding(.top, 8)
    }
}

/// A photo with its caption under it.
struct Figure: View {
    let photoId: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncPhoto(photoId: photoId)
                .frame(maxWidth: .infinity)
                .frame(height: 224)
                .clipShape(RoundedRectangle(cornerRadius: Zine.radiusMedium))
            Text(caption).font(.zBodySmall).foregroundStyle(Zine.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

extension AppModel {
    /// A link inside a collection sheet leads away: the sheet closes first.
    func collectionDetailDismissed() {
        collectionSheetCloseRequest += 1
    }
}
