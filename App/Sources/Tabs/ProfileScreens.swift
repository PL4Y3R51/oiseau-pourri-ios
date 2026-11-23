import SwiftUI
import OiseauCore

// The Profil tab and other players' profiles (Android: ui/profile/ProfileScreens.kt,
// ProfileViewModels.kt). A profile's birds are read from the map list the app already
// holds, so they follow the map's disclosure rules (spec §4.5).

/// Who a profile is about.
struct ProfileHead: Equatable {
    var name: String
    var image: String?
    /// Only on my own profile.
    var email: String?
    /// nil until loaded, and for an admin (no public profile).
    var placed: Int?
    var found: Int?
}

/// The Profil tab: my public counts and my birds. Everything editable is behind the gear.
struct MyProfileScreen: View {
    @Environment(AppModel.self) private var app
    @State private var counts: PublicProfile?

    init() {}

    var body: some View {
        let user = app.session.user
        ProfileBody(
            head: ProfileHead(name: user?.name ?? "", image: user?.image, email: user?.email, placed: counts?.placedCount, found: counts?.foundCount),
            userId: user?.id ?? "",
            mine: true
        )
        .navigationTitle(L("profile_mine"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) { LucideIcon("settings", size: 22) }
                    .accessibilityLabel(L("profile_settings"))
                    .accessibilityIdentifier("profile.settings")
            }
        }
        .task(id: user?.id) {
            guard let id = user?.id else { return }
            counts = try? await app.cached("user-\(id)") {
                guard let p = try await app.api.get("/api/users/\(id)", as: PublicProfile.self) else { throw ApiError(status: 404, code: "not_found") }
                return p
            }.value
        }
    }
}

/// Another player, reached from a placer, a finder or the leaderboard. Admins answer 404.
struct PublicProfileScreen: View {
    @Environment(AppModel.self) private var app
    let userId: String
    @State private var profile: PublicProfile?
    @State private var error: UiText?

    init(userId: String) {
        self.userId = userId
    }

    var body: some View {
        Group {
            if let profile {
                ProfileBody(
                    head: ProfileHead(name: profile.displayName, image: profile.image, placed: profile.placedCount, found: profile.foundCount),
                    userId: userId,
                    mine: userId == app.session.user?.id
                )
            } else if let error {
                Text(error.text).font(.zBody).foregroundStyle(Zine.error).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LoadingView()
            }
        }
        .background(Zine.paper)
        .navigationTitle(L("profile_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: userId) {
            do {
                profile = try await app.cached("user-\(userId)") {
                    guard let p = try await app.api.get("/api/users/\(userId)", as: PublicProfile.self) else { throw ApiError(status: 404, code: "not_found") }
                    return p
                }.value
            } catch {
                let e = error as? ApiError
                // `not_found` → « Utilisateur introuvable. » (admins and deleted accounts too).
                self.error = (e?.code == "not_found" || e?.status == 404) ? .of("profile_not_found") : uiText(error)
            }
        }
    }
}

/// The identity card and the bird grid, shared by both profiles.
private struct ProfileBody: View {
    @Environment(AppModel.self) private var app
    let head: ProfileHead
    let userId: String
    let mine: Bool
    /// How many birds show before « Voir plus » (web: PAGE).
    private static let page = 12
    @State private var shown = ProfileBody.page
    @State private var open: MapSticker?

    init(head: ProfileHead, userId: String, mine: Bool) {
        self.head = head
        self.userId = userId
        self.mine = mine
    }

    var body: some View {
        let birds = app.stickers.map { birdsPlacedBy($0, userId: userId) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                IdentityCard(head: head)
                SectionTitle(text: L(mine ? "profile_birds_mine" : "profile_birds")).padding(.top, 10)
                if let birds {
                    if birds.isEmpty {
                        Text(L(mine ? "profile_birds_empty_mine" : "profile_birds_empty")).font(.zBody).foregroundStyle(Zine.muted)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                            ForEach(birds.prefix(shown), id: \.id) { s in
                                Button { open = s } label: { BirdCard(sticker: s, thumb: thumb(s)) }
                                    .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
                                    .accessibilityLabel(L("profile_bird_open", s.placeName, L(s.seenByMe ? "profile_bird_seen" : "profile_bird_unseen")))
                            }
                        }
                        if birds.count > shown {
                            OpButton(title: L("profile_birds_more", birds.count - shown), variant: .secondary, fullWidth: true) { shown += Self.page }
                        }
                    }
                } else {
                    Text(L("common_loading")).font(.zBody).foregroundStyle(Zine.muted)
                }
            }
            .padding(16)
            .padding(.trailing, Zine.pressOffset)
        }
        .background(Zine.paper)
        .refreshable { await app.refreshMap(force: true) }
        .task { await app.refreshMap() }
        .sheet(item: $open) { s in
            ProfileBirdDetail(sticker: s, thumb: thumb(s)) {
                open = nil
                app.showOnMap(s)
            } onReveal: {
                Task { await app.revealSpoiler(s.id) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Zine.panel)
        }
    }

    private func thumb(_ s: MapSticker) -> BirdThumb {
        birdThumb(s, hideSpoilers: app.prefs?.hideMapSpoilers ?? false, revealed: app.prefs?.revealedSpoilers.contains(s.id) ?? false)
    }
}

/// A section title with the pink pastille (Android: SectionTitle).
struct SectionTitle: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Zine.pink).frame(width: 12, height: 12).overlay(Rectangle().stroke(Zine.ink, lineWidth: 1.5))
            Text(text).font(.zTitle).foregroundStyle(Zine.ink)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct IdentityCard: View {
    let head: ProfileHead

    var body: some View {
        HStack(spacing: 14) {
            Avatar(image: head.image, size: 72)
                .overlay(Circle().stroke(Zine.ink, lineWidth: 3))
            VStack(alignment: .leading, spacing: 4) {
                Text(head.name).font(.zTitleLarge).foregroundStyle(Zine.ink)
                if let email = head.email { Text(email).font(.zBody).foregroundStyle(Zine.muted) }
                if let placed = head.placed, let found = head.found {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { counts(placed, found) }
                        VStack(alignment: .leading, spacing: 4) { counts(placed, found) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Zine.panel)
        .floating(RoundedRectangle(cornerRadius: Zine.radiusMedium))
    }

    @ViewBuilder private func counts(_ placed: Int, _ found: Int) -> some View {
        Count(icon: "map_pin", text: L("profile_placed", placed))
        Count(icon: "target", text: L("profile_found", found))
    }

    private struct Count: View {
        let icon: String
        let text: String
        var body: some View {
            HStack(spacing: 4) {
                LucideIcon(icon, size: 14)
                Text(text).font(.zBody).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Zine.muted)
        }
    }
}

/// A bird's card: the picture in colour or black and white, the place, the date.
private struct BirdCard: View {
    let sticker: MapSticker
    let thumb: BirdThumb

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BirdPicture(thumb: thumb, thumbSize: true)
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if sticker.status == .archived {
                        Text(L("collection_card_archived")).font(.zLabelSmall).foregroundStyle(Zine.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Zine.yellow, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Zine.ink, lineWidth: 1))
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    if sticker.isPrivate { LucideIcon("house", size: 11) }
                    Text(sticker.placeName).font(.syne(12.5, 700)).lineLimit(2).multilineTextAlignment(.leading)
                }
                .foregroundStyle(Zine.ink)
                Text(shortDate(sticker.placedAt)).font(.zBodySmall).foregroundStyle(Zine.muted)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Zine.panel)
    }
}

/// The picture of a bird on a profile: greyed until found, blurred while a spoiler, or the mascot.
struct BirdPicture: View {
    let thumb: BirdThumb
    var thumbSize = false

    var body: some View {
        Group {
            if let id = thumb.photoId {
                AsyncPhoto(photoId: id, thumb: thumbSize)
                    .blur(radius: thumb.blurred ? 14 : 0)
                    .scaleEffect(thumb.blurred ? 1.08 : 1)
            } else {
                Mascotte(.photo)
            }
        }
        .grayscale(thumb.tone == .grey ? 1 : 0)
        .clipped()
    }
}

/// A bird opened in full: place, date, status, the picture, its text, « Voir sur la carte ».
private struct ProfileBirdDetail: View {
    let sticker: MapSticker
    let thumb: BirdThumb
    let onMap: () -> Void
    let onReveal: () -> Void

    var body: some View {
        let s = sticker
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    LucideIcon("map_pin", size: 20)
                    Text(s.placeName).font(.zTitleLarge).accessibilityAddTraits(.isHeader)
                }
                .foregroundStyle(Zine.ink)
                HStack(spacing: 6) {
                    LucideIcon("calendar", size: 14)
                    Text(L("detail_placed_on", longDate(s.placedAt) ?? s.placedAt)).font(.zBody)
                    if s.isPrivate {
                        LucideIcon("house", size: 14)
                        Text(L("sheet_private")).font(.zBody)
                    }
                }
                .foregroundStyle(Zine.muted)
                if s.status == .archived {
                    HStack(spacing: 6) {
                        LucideIcon("archive", size: 15)
                        Text(L("profile_bird_archived")).font(.zBody)
                    }
                    .foregroundStyle(Zine.archivedInk)
                }
                ZStack {
                    BirdPicture(thumb: thumb)
                    if thumb.blurred {
                        Zine.ink.opacity(0.45)
                        HStack(spacing: 8) {
                            LucideIcon("eye", size: 18)
                            Text(L("sheet_spoiler")).font(.zLabel)
                        }
                        .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 224)
                .clipShape(RoundedRectangle(cornerRadius: Zine.radiusMedium))
                .overlay(RoundedRectangle(cornerRadius: Zine.radiusMedium).stroke(Zine.ink, lineWidth: Zine.lineWidth))
                .onTapGesture { if thumb.blurred { onReveal() } }
                if let text = s.seenByMe ? s.description : s.hint {
                    Text(text).font(.zBody).foregroundStyle(Zine.ink)
                }
                StatusText(sticker: s)
                if s.status != .archived {
                    OpButton(title: L("profile_bird_on_map"), icon: "map", fullWidth: true, action: onMap)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
        }
    }

    private struct StatusText: View {
        let sticker: MapSticker
        var body: some View {
            let (key, color): (String, Color) = sticker.placedByMe ? ("profile_bird_mine", Zine.pink)
                : sticker.state == .found ? ("profile_bird_found", Zine.found) : ("profile_bird_not_found", Zine.muted)
            Text(L(key)).font(.syne(14, 700)).foregroundStyle(color)
        }
    }
}

/// "28.09.2026", in the reader's language.
func shortDate(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
    return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(appLocale))
}

extension MapSticker: Identifiable {}
