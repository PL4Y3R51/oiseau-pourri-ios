import SwiftUI
import Observation
import OiseauCore

/// The Classement tab (Android: ui/leaderboard/Leaderboard.kt). Admins are left out server-side.
enum Board: CaseIterable, Hashable { case placers, finders }

/// The periods the board offers, opening on the month (spec §4.9).
let boardPeriods: [LeaderboardPeriod] = [.month, .year, .all]

func periodLabel(_ p: LeaderboardPeriod) -> String {
    switch p {
    case .year: return L("leaderboard_year")
    case .all: return L("leaderboard_all")
    default: return L("leaderboard_month")
    }
}

/// « Personne au classement pour l'instant. » and its variants.
func leaderboardEmpty(_ period: LeaderboardPeriod, abroad: Bool) -> String {
    switch (period, abroad) {
    case (.all, false): return L("leaderboard_empty")
    case (.all, true): return L("leaderboard_empty_abroad_all")
    case (.year, false): return L("leaderboard_empty_year")
    case (.year, true): return L("leaderboard_empty_abroad_year")
    case (_, true): return L("leaderboard_empty_abroad_month")
    default: return L("leaderboard_empty_month")
    }
}

@MainActor
@Observable
final class LeaderboardModel {
    var board: Board = .placers
    private(set) var period: LeaderboardPeriod = .month
    private(set) var abroad = false
    /// The last board loaded; it stays (dimmed) while the next one loads.
    private(set) var data: LeaderboardResponse?
    private(set) var loading = true
    private(set) var error: UiText?
    private(set) var staleSince: Date?

    func load(_ app: AppModel) async {
        loading = true
        let scope = abroad ? "abroad" : "all"
        let path = "/api/leaderboard?period=\(period.rawValue)&scope=\(scope)"
        do {
            let fetched = try await app.cached("leaderboard-\(period.rawValue)-\(scope)") {
                try await app.api.get(path, as: LeaderboardResponse.self) ?? LeaderboardResponse(placers: [], finders: [])
            }
            data = fetched.value
            staleSince = fetched.staleSince
            error = nil
        } catch {
            self.error = uiText(error)
            staleSince = nil
        }
        loading = false
    }

    func setPeriod(_ p: LeaderboardPeriod, _ app: AppModel) async {
        period = p
        await load(app)
    }

    func toggleAbroad(_ app: AppModel) async {
        abroad.toggle()
        await load(app)
    }
}

struct LeaderboardScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = LeaderboardModel()

    init() {}

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $model.board) {
                        Text(L("leaderboard_placers")).tag(Board.placers)
                        Text(L("leaderboard_finders")).tag(Board.finders)
                    }
                    .pickerStyle(.segmented)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(boardPeriods, id: \.self) { p in
                                FilterChip(label: periodLabel(p), on: model.period == p) { Task { await model.setPeriod(p, app) } }
                            }
                            FilterChip(label: L("leaderboard_abroad"), on: model.abroad, icon: "globe") { Task { await model.toggleAbroad(app) } }
                        }
                        .padding(.trailing, Zine.pressOffset)
                        .padding(.bottom, Zine.pressOffset)
                    }
                }
                .padding(.bottom, 4)

                if let since = model.staleSince { StaleBanner(since: since) }
                if let error = model.error { Text(error.text).font(.zBody).foregroundStyle(Zine.ink) }

                if model.data == nil && model.loading {
                    LoadingView().frame(height: 200)
                } else {
                    let entries = model.board == .placers ? model.data?.placers ?? [] : model.data?.finders ?? []
                    if entries.isEmpty && model.error == nil {
                        EmptyStateView(text: leaderboardEmpty(model.period, abroad: model.abroad))
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.userId) { i, e in
                        NavigationLink(value: Route.profile(userId: e.userId)) {
                            LeaderboardRow(rank: i + 1, entry: e, me: e.userId == app.session.user?.id, board: model.board)
                        }
                        .buttonStyle(.plain)
                        .opacity(model.loading ? 0.5 : 1)
                    }
                }

                PressRow(title: L("leaderboard_order"), icon: "package") { app.push(.order, on: .leaderboard) }
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Zine.paper)
        .navigationTitle(L("tab_leaderboard"))
        .refreshable { await model.load(app) }
        .task { if model.data == nil { await model.load(app) } }
    }
}

/// Rank (gold, silver, bronze for the podium), avatar, name, count.
struct LeaderboardRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let me: Bool
    let board: Board

    var body: some View {
        let rankColor: Color = switch rank {
        case 1: Color(hex: 0xB8901A)
        case 2: Color(hex: 0x8A8A8A)
        case 3: Color(hex: 0xA0602A)
        default: Zine.muted
        }
        HStack(spacing: 10) {
            Text("\(rank)").font(.syne(16, 700)).foregroundStyle(rankColor).frame(width: 26)
            Avatar(image: entry.image)
            Text(entry.displayName).font(.syne(16, 700)).foregroundStyle(Zine.ink).lineLimit(1)
            Spacer(minLength: 4)
            Text(L(board == .placers ? "leaderboard_count_placed" : "leaderboard_count_found", entry.count))
                .font(.zBodySmall).foregroundStyle(Zine.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Zine.panel, in: RoundedRectangle(cornerRadius: Zine.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Zine.radiusMedium).stroke(Zine.ink, lineWidth: me ? 2.5 : Zine.lineWidth))
        .contentShape(Rectangle())
    }
}
