import SwiftUI
import UIKit
import OiseauCore

/// The bird sheet, read-only in this step (Android: ui/map/StickerSheet.kt). What it
/// may show is decided by the server — a hint only while not found, a description
/// only once found — and by the per-user kind.
struct StickerSheetView: View {
    let sticker: MapSticker
    var onClose: () -> Void = {}
    @State private var spoilerRevealed = false

    init(sticker: MapSticker, onClose: @escaping () -> Void = {}) {
        self.sticker = sticker
        self.onClose = onClose
    }

    var body: some View {
        ScrollView {
            StickerSheetContent(sticker: sticker, spoilerRevealed: $spoilerRevealed, onClose: onClose)
                .padding(.top, 20)
        }
    }
}

struct StickerSheetContent: View {
    let sticker: MapSticker
    @Binding var spoilerRevealed: Bool
    var onClose: () -> Void = {}

    var body: some View {
        let s = sticker
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KindBadge(kind: s.pinKind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.placeName).font(.zTitle).foregroundStyle(Zine.ink)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 4) {
                        LucideIcon("user_round", size: 13)
                        Text(L("sheet_placed_by", s.placedByName)).font(.zBodySmall)
                    }
                    .foregroundStyle(Zine.muted)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    LucideIcon("x", size: 20).foregroundStyle(Zine.ink).frame(width: 44, height: 44)
                }
                .accessibilityLabel(L("common_close"))
            }

            if s.status == .archived { StatusLine(icon: "archive", text: L("sheet_archived"), color: Zine.archivedInk) }
            if s.isPrivate { StatusLine(icon: "house", text: L("sheet_private"), color: Zine.privateInk) }

            if s.foundByMe {
                if let id = s.findPhotoId { SheetPhoto(photoId: id, label: L("sheet_trophy")) }
                if let d = s.description { Text(d).font(.zBody).foregroundStyle(Zine.ink) }
                StatusLine(icon: "target", text: foundLine(s), color: Zine.found)
            } else if s.placedByMe {
                if let id = s.placementPhotoId { SheetPhoto(photoId: id, label: L("sheet_my_placement")) }
                if let d = s.description { Text(d).font(.zBody).foregroundStyle(Zine.ink) }
                StatusLine(icon: "map_pin", text: L("sheet_mine"), color: Zine.pink)
                if s.hasOpenReport == true { StatusLine(icon: "flag", text: L("sheet_reported"), color: Zine.ink) }
            } else if s.pinKind == .available {
                if let id = s.placementPhotoId {
                    SpoilerPhoto(photoId: id, revealed: $spoilerRevealed)
                }
                if let hint = s.hint {
                    HStack(alignment: .top, spacing: 8) {
                        LucideIcon("lightbulb", size: 16).foregroundStyle(Zine.wishInk)
                        Text(hint).font(.zBody).foregroundStyle(Zine.ink)
                    }
                } else {
                    Text(L("sheet_no_hint")).font(.zBody).foregroundStyle(Zine.muted)
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.bottom, 20)
        .accessibilityIdentifier("sheet")
    }

    private func foundLine(_ s: MapSticker) -> String {
        guard let date = s.foundAt.flatMap(longDate) else { return L("sheet_in_collection") }
        return L("sheet_in_collection_on", date)
    }
}

/// "1 octobre 2026", in the reader's language.
func longDate(_ iso: String) -> String? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
    return date.formatted(date: .long, time: .omitted)
}

/// Round badge in the kind's colour.
struct KindBadge: View {
    let kind: PinKind
    var size: CGFloat = 40

    var body: some View {
        let color = Color(Zine.pin(kind))
        LucideIcon("map_pin", size: size * 0.45)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(kind == .available ? 0.14 : 0.2), in: Circle())
    }
}

private struct StatusLine: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(icon, size: 16)
            Text(text).font(.zBody)
        }
        .foregroundStyle(color)
    }
}

/// A stored photo, loaded with the session cookie (`/api/photos/:id`, WebP).
struct AsyncPhoto: View {
    @Environment(AppModel.self) private var model
    let photoId: String
    @State private var image: UIImage?
    @State private var failed = false

    init(photoId: String) {
        self.photoId = photoId
    }

    var body: some View {
        ZStack {
            Zine.surfaceVariant
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed || AppConfig.stubApi {
                // The stub has no photos: the mascot stands in, like Android's screenshots.
                Mascotte(.photo).opacity(0.9)
            } else {
                ProgressView()
            }
        }
        .task(id: photoId) {
            guard !AppConfig.stubApi else { return }
            do {
                if let data = try await model.api.photo(photoId), let decoded = UIImage(data: data) { image = decoded } else { failed = true }
            } catch {
                failed = true
            }
        }
    }
}

private struct SheetPhoto: View {
    let photoId: String
    let label: String

    var body: some View {
        AsyncPhoto(photoId: photoId)
            .frame(maxWidth: .infinity)
            .frame(height: 224)
            .clipShape(RoundedRectangle(cornerRadius: Zine.radiusMedium))
            .accessibilityLabel(label)
    }
}

/// The placer's photo as a hunting hint (spec §4.4): blurred until the first tap.
private struct SpoilerPhoto: View {
    let photoId: String
    @Binding var revealed: Bool

    var body: some View {
        ZStack {
            AsyncPhoto(photoId: photoId)
                .blur(radius: revealed ? 0 : 18)
                .scaleEffect(revealed ? 1 : 1.08)
            if !revealed {
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
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { revealed = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(revealed ? "sheet_spoiler_alt" : "sheet_spoiler_reveal"))
        .accessibilityAddTraits(.isButton)
    }
}

/// « N oiseaux pourris ici »: the birds stacked under one tap.
struct StickerGallery: View {
    let stickers: [MapSticker]
    let onPick: (MapSticker) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(stickers, id: \.id) { s in
                    Button { onPick(s) } label: {
                        HStack(spacing: 12) {
                            KindBadge(kind: s.pinKind, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.placeName).font(.zTitle).foregroundStyle(Zine.ink)
                                Text(L("sheet_placed_by", s.placedByName)).font(.zBodySmall).foregroundStyle(Zine.muted)
                            }
                            Spacer()
                            LucideIcon("chevron_right", size: 18).foregroundStyle(Zine.muted)
                        }
                        .padding(12)
                        .background(Zine.panel)
                    }
                    .buttonStyle(PressedRelief(shape: RoundedRectangle(cornerRadius: Zine.radiusMedium)))
                }
            }
            .padding(20)
        }
    }
}
