import SwiftUI
import OiseauCore

// The offline side of the game, on screen (Android: ui/sync/*): the band while the
// server can't be reached, the banner of what waits, and the list of it.

/// Across the top while the server can't be reached (issue #89): whose side it is on,
/// and that playing goes on. Closed (×) down to a slim « Mode hors connexion » strip.
struct ReachabilityBanner: View {
    let reach: Reach
    let collapsed: Bool
    let onCollapsed: (Bool) -> Void

    var body: some View {
        if reach != .online {
            if collapsed {
                Button { onCollapsed(false) } label: {
                    HStack(spacing: 6) {
                        LucideIcon("cloud_off", size: 12)
                        Text(L("reach_slim")).font(.syne(11, 700))
                    }
                    .foregroundStyle(Zine.yellow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Zine.ink)
                }
                .buttonStyle(.plain)
                .accessibilityHint(L("reach_expand"))
                .accessibilityIdentifier("reach.slim")
            } else {
                HStack(spacing: 10) {
                    LucideIcon("cloud_off", size: 18).foregroundStyle(Zine.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(reach == .noNetwork ? "reach_offline" : "reach_server_down")).font(.syne(16, 700)).foregroundStyle(Zine.yellow)
                        Text(L("reach_hint")).font(.zBodySmall).foregroundStyle(Zine.paper)
                    }
                    Spacer(minLength: 0)
                    Button { onCollapsed(true) } label: {
                        LucideIcon("x", size: 20).foregroundStyle(Zine.paper).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L("reach_collapse"))
                }
                .padding(.leading, 16)
                .padding(.vertical, 4)
                .background(Zine.ink)
                .accessibilityIdentifier("reach.band")
            }
        }
    }
}

/// « N éléments pas encore synchronisés », on the map; a tap opens the list.
struct PendingSyncBanner: View {
    let queue: [QueuedAction]
    let onOpen: () -> Void

    var body: some View {
        let pending = queue.filter { $0.status == .pending }.count
        let failed = queue.filter { $0.status == .failed }.count
        if pending + failed > 0 {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    LucideIcon(failed > 0 ? "flag" : "cloud_off", size: 16)
                    Text(failed > 0 ? L("sync_banner_failed", failed) : L("sync_banner_pending", pending)).font(.syne(13, 700))
                    LucideIcon("chevron_right", size: 14)
                }
                .foregroundStyle(Zine.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(failed > 0 ? Zine.pink : Zine.yellow)
            }
            .buttonStyle(PressedRelief(shape: Capsule()))
            .accessibilityIdentifier("sync.banner")
        }
    }
}

/// What waits on the device: each item, why a refused one failed, and « Ignorer ».
struct SyncQueueSheet: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false

    init() {}

    var body: some View {
        let items = app.myQueue
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    LucideIcon("cloud_off", size: 20)
                    Text(L("sync_title")).font(.zTitleLarge)
                }
                .foregroundStyle(Zine.ink)
                Text(L("sync_body")).font(.zBody).foregroundStyle(Zine.muted)
                OpButton(title: L(busy ? "sync_retry_busy" : "sync_retry"), icon: "refresh_cw", variant: .secondary, fullWidth: true) {
                    Task {
                        busy = true
                        await app.drain()
                        busy = false
                    }
                }
                .disabled(busy)
                ForEach(items, id: \.id) { QueueRow(action: $0) }
            }
            .padding(20)
        }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var app
    let action: QueuedAction

    var body: some View {
        let a = action
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let data = app.queue.photo(of: a), let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Mascotte(.photo)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(a.placeName.isEmpty ? L(kindKey(a.kind)) : a.placeName).font(.syne(14, 700)).foregroundStyle(Zine.ink)
                Text(L("sync_row_meta", L(kindKey(a.kind)), Date(timeIntervalSince1970: TimeInterval(a.capturedAt) / 1000).formatted(date: .abbreviated, time: .shortened)))
                    .font(.zBodySmall).foregroundStyle(Zine.muted)
                if a.status == .failed {
                    Text(a.failureReason().text).font(.zBodySmall).foregroundStyle(Zine.error)
                }
            }
            Spacer(minLength: 0)
            Button { app.discard(a) } label: {
                HStack(spacing: 4) {
                    LucideIcon("trash_2", size: 14)
                    Text(L("sync_ignore")).font(.zBodySmall)
                }
                .foregroundStyle(Zine.error)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("sync_ignore_a11y"))
        }
        .padding(12)
        .background(Zine.paper, in: RoundedRectangle(cornerRadius: Zine.radiusMedium))
    }

    private func kindKey(_ k: QueuedKind) -> String {
        switch k {
        case .find: return "sync_kind_find"
        case .placement: return "sync_kind_placement"
        case .report: return "sync_kind_report"
        case .wishlist: return "sync_kind_wishlist"
        case .stickerToggle: return "sync_kind_toggle"
        case .stickerEdit: return "sync_kind_edit"
        case .stickerDelete: return "sync_kind_delete"
        case .prefs: return "sync_kind_prefs"
        }
    }
}
