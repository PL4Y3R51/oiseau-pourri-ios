import Foundation
import Testing
@testable import OiseauCore

/// The app's wire types against real API answers, recorded by the API's integration
/// suite (apps/api/tests/integration/androidContract.test.ts) and copied here by
/// tools/sync-from-monorepo.mjs. When the API changes a shape, this is the test that
/// tells the iOS side.
struct ContractTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The JSON keys a fully filled value encodes to: every field the app reads.
    private func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        Set(try object(ApiJson.encoder.encode(value)).keys)
    }

    /// Every field we declare must be in the fixture (no silent default); extra server fields are fine.
    private func requireFields<T: Encodable>(_ name: String, _ json: [String: Any], like full: T) throws {
        let missing = try keys(full).subtracting(json.keys)
        #expect(missing.isEmpty, "\(name) lacks fields the app reads: \(missing.sorted())")
    }

    @Test func session() throws {
        let data = try fixture("get-session.json")
        let root = try object(data)
        try requireFields("user", try #require(root["user"] as? [String: Any]), like: AuthUser(id: "", email: "", name: "", image: ""))
        try requireFields("session", try #require(root["session"] as? [String: Any]), like: SessionInfo(id: "", userId: "", expiresAt: ""))
        let s = try ApiJson.decoder.decode(AuthSession.self, from: data)
        #expect(s.user.name == "Player")
        #expect(!s.user.isAdmin)
        #expect(s.user.image == nil)
    }

    @Test func profile() throws {
        let data = try fixture("profile.json")
        try requireFields("profile", try object(data), like: PublicUser(id: "", email: "", displayName: "", image: "", isAdmin: false))
        #expect(try ApiJson.decoder.decode(PublicUser.self, from: data).displayName == "Player")
    }

    @Test func defaultPrefs() throws {
        let prefs = try ApiJson.decoder.decode(UserPrefs.self, from: try fixture("prefs-default.json"))
        #expect(prefs.mapStyle == nil)
        #expect(!prefs.onboarded)
        #expect(MapStyle.of(prefs.mapStyle) == .liberty)
    }

    @Test func errorShapes() throws {
        #expect(ApiError.from(status: 401, body: try fixture("error-401.json")).isUnauthorized)
        #expect(ApiError.from(status: 400, body: try fixture("error-invalid-input.json")).code == "invalid_input")
    }

    // A wrong password reads the same in every form: Better Auth's code, and the
    // API's change-email hook answering with it too.
    @Test(arguments: ["change-password-wrong.json", "change-email-wrong.json", "delete-user-wrong.json"])
    func aWrongPasswordIsWordedByTheApp(name: String) throws {
        let e = ApiError.from(status: 400, body: try fixture(name))
        #expect(e.code == "INVALID_PASSWORD")
        #expect(authErrorMessage(e, fallback: "account_failed") == .of("auth_error_password"))
    }

    @Test func aDeadEmailLinkIsWordedByTheApp() throws {
        let reset = ApiError.from(status: 400, body: try fixture("reset-password-invalid.json"))
        #expect(resetErrorMessage(reset) == .of("reset_invalid"))
        let verify = ApiError.from(status: 401, body: try fixture("verify-email-invalid.json"))
        #expect(authErrorMessage(verify, fallback: "account_failed") == .of("auth_error_link"))
    }

    // An older app must keep decoding a newer server: new fields and new enum values.
    @Test func newFieldsAndValuesDontBreakTheMap() throws {
        var json = try object(ApiJson.encoder.encode([SampleStickers.available])[...].dropFirst().dropLast().reduce(into: Data()) { $0.append($1) })
        json["status"] = "hibernating"
        json["glitter"] = true
        let data = try JSONSerialization.data(withJSONObject: [json])
        let decoded = try ApiJson.decoder.decode([MapSticker].self, from: data)
        #expect(decoded.first?.status == .unknown)
    }
}
