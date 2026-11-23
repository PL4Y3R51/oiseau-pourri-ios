import Foundation

/// Claiming and reporting birds (`POST /api/finds`, `POST /api/reports`; Android:
/// data/HuntRepository.kt). The server checks proximity against the position sent,
/// within the bird's radius; the app never decides it. [photo]: the JPEG to upload,
/// already prepared ([PhotoPreparer]).
@MainActor
public final class HuntRepository {
    private let api: ApiClient
    private let clock: () -> Date

    public init(api: ApiClient, clock: @escaping () -> Date = Date.init) {
        self.api = api
        self.clock = clock
    }

    /// web: FindSheet — `capturedAt` is the submit time, or the gesture's for an offline replay.
    @discardableResult
    public func find(stickerId: String, at: Position, photo: Data, capturedAt: Int64? = nil) async throws(ApiError) -> CreateFindResponse? {
        var form = MultipartForm()
        form.add("stickerId", stickerId)
        form.add("lng", "\(at.point.lng)")
        form.add("lat", "\(at.point.lat)")
        form.add("capturedAt", "\(capturedAt ?? epochMs(clock()))")
        form.add("photo", filename: "find.jpg", data: photo)
        return try await api.postForm("/api/finds", form, as: CreateFindResponse.self, timeout: ApiClient.gestureTimeout)
    }

    /// web: ReportSheet — the note only when not blank, no capture time.
    @discardableResult
    public func report(stickerId: String, at: Position, photo: Data, note: String) async throws(ApiError) -> CreatedResponse? {
        var form = MultipartForm()
        form.add("stickerId", stickerId)
        form.add("lng", "\(at.point.lng)")
        form.add("lat", "\(at.point.lat)")
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { form.add("note", note) }
        form.add("photo", filename: "report.jpg", data: photo)
        return try await api.postForm("/api/reports", form, as: CreatedResponse.self, timeout: ApiClient.gestureTimeout)
    }
}
