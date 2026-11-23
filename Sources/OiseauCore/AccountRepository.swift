import Foundation

struct VerificationEmailRequest: Encodable { var email: String }
/// `currentPassword` is ours (the API's change-email hook), not Better Auth's.
struct ChangeEmailRequest: Encodable { var newEmail: String; var currentPassword: String }
struct ChangePasswordRequest: Encodable { var currentPassword: String; var newPassword: String; var revokeOtherSessions: Bool }
struct DeleteUserRequest: Encodable { var password: String }

/// Réglages ▸ Compte et sécurité (Android: data/AccountRepository.kt; web:
/// AccountSettingsPage): the profile (`/api/profile`) and the account itself —
/// Better Auth's e-mail, password and deletion endpoints, the same ones the web's
/// auth client calls. Their error answers are pinned by the contract fixtures; word
/// them with [authErrorMessage].
@MainActor
public final class AccountRepository {
    private let api: ApiClient
    private let auth: AuthRepository
    private let queue: OfflineQueue
    private let map: MapRepository

    public init(api: ApiClient, auth: AuthRepository, queue: OfflineQueue, map: MapRepository) {
        self.api = api
        self.auth = auth
        self.queue = queue
        self.map = map
    }

    /// Name and/or avatar (a prepared JPEG). The session is then read past Better
    /// Auth's 5-minute cookie cache: the API writes the user row directly, so the
    /// cached session would otherwise keep the old name and photo.
    public func updateProfile(name: String?, avatar: Data?) async throws(ApiError) {
        var form = MultipartForm()
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { form.add("name", name) }
        if let avatar { form.add("avatar", filename: "avatar.jpg", data: avatar) }
        _ = try await api.postForm("/api/profile", form, as: Ignored.self)
        try await auth.refresh(fresh: true)
    }

    public func resendVerification(email: String) async throws(ApiError) {
        _ = try await api.post("/auth/send-verification-email", VerificationEmailRequest(email: email), as: Ignored.self)
    }

    /// Two mails when the address is confirmed: the old one approves, then the new one confirms.
    public func changeEmail(_ newEmail: String, currentPassword: String) async throws(ApiError) {
        let body = ChangeEmailRequest(newEmail: newEmail.trimmingCharacters(in: .whitespacesAndNewlines), currentPassword: currentPassword)
        _ = try await api.post("/auth/change-email", body, as: Ignored.self)
    }

    /// Revokes the other sessions; this one gets a fresh cookie (the jar keeps it).
    public func changePassword(current: String, new: String) async throws(ApiError) {
        _ = try await api.post("/auth/change-password", ChangePasswordRequest(currentPassword: current, newPassword: new, revokeOtherSessions: true), as: Ignored.self)
    }

    /// The nLPD export: a ZIP of the account's data and photos, as is.
    public func export() async throws(ApiError) -> Data {
        try await api.send("GET", "/api/me/export") ?? Data()
    }

    /// Permanent (spec §4.1, nLPD erasure): Better Auth checks the password, the API
    /// purges the account's data. What the device holds for it goes too — its parked
    /// actions and their photos would otherwise outlive the account here.
    public func deleteAccount(password: String, userId: String) async throws(ApiError) {
        _ = try await api.post("/auth/delete-user", DeleteUserRequest(password: password), as: Ignored.self)
        queue.clearFor(userId)
        map.clear()
        await auth.signOut()
    }
}
