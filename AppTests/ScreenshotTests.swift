import SwiftUI
import UIKit
import XCTest
import OiseauCore
@testable import OiseauPourri

/// Every screen of this step, drawn in a real window of the simulator and saved as
/// PNG: the iOS side of Android's Roborazzi screenshots. CI passes
/// TEST_RUNNER_SCREENSHOT_DIR, so the images land on the runner and are uploaded.
/// They are looked at by a person, not compared yet.
@MainActor
final class ScreenshotTests: XCTestCase {
    /// An iPhone 15/16 screen, in points.
    private let phone = CGSize(width: 393, height: 852)

    /// A model signed in to the stub, its prefs and map loaded, as after a real sign-in.
    private func signedInModel(_ prefs: UserPrefs? = nil) async throws -> AppModel {
        let model = AppModel.preview()
        try await model.auth.signIn(email: StubServer.email, password: StubServer.password)
        for _ in 0..<40 where model.prefs == nil || model.stickers == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        return model
    }

    private func snap<V: View>(_ name: String, model: AppModel, size: CGSize? = nil, wait: TimeInterval = 1.0, _ view: V) throws {
        let frame = CGRect(origin: .zero, size: size ?? phone)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let host = UIHostingController(rootView: view.environment(model).environment(model.location).tint(Zine.ink))
        if size != nil { host.safeAreaRegions = [] }
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = frame
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        let image = UIGraphicsImageRenderer(bounds: frame).image { _ in
            window.drawHierarchy(in: frame, afterScreenUpdates: true)
        }
        window.isHidden = true
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTabs() async throws {
        let model = try await signedInModel()
        try snap("tab-collection", model: model, NavigationStack { CollectionScreen() })
        try snap("tab-leaderboard", model: model, NavigationStack { LeaderboardScreen() })
        try snap("tab-profile", model: model, NavigationStack { MyProfileScreen() })
        try snap("tab-place-charter", model: model, NavigationStack { PlaceScreen() })
        try snap("profile-public", model: model, NavigationStack { PublicProfileScreen(userId: "u-alice") })
    }

    func testSettingsPages() async throws {
        let model = try await signedInModel()
        try snap("settings", model: model, NavigationStack { SettingsScreen() })
        try snap("settings-preferences", model: model, NavigationStack { PreferencesScreen() })
        try snap("settings-account", model: model, NavigationStack { AccountScreen() })
        try snap("settings-order", model: model, NavigationStack { OrderScreen() })
        try snap("settings-order-history", model: model, NavigationStack { OrderHistoryScreen() })
        try snap("settings-offline-maps", model: model, NavigationStack { OfflineMapsScreen() })
    }

    func testFlows() async throws {
        let model = try await signedInModel()
        try snap("hunt-find", model: model, HuntSheet(model: HuntModel(kind: .find, sticker: SampleStickers.available, position: Position(GeoPoint.lausanne, accuracyM: 8))) {})
        try snap("hunt-report", model: model, HuntSheet(model: HuntModel(kind: .report, sticker: SampleStickers.found, position: nil)) {})
        try snap("edit-sticker", model: model, EditStickerView(target: EditTarget(map: SampleStickers.mine, now: parseIsoDate(SampleStickers.placedAt)!.addingTimeInterval(60))))
        try snap("place-queued", model: model, PlaceQueued(serverDown: true) {})
        try snap("terms-gate", model: model, TermsGate {})
        try snap("reset-password", model: model, ResetPasswordView(token: "tok") {})
        try snap("sheet-with-actions", model: model, size: CGSize(width: 393, height: 620),
                 StickerSheetView(sticker: SampleStickers.available, actions: SheetActions()).background(Zine.panel))
    }

    func testOfflineViews() async throws {
        let model = try await signedInModel()
        let banners = VStack(spacing: 20) {
            ReachabilityBanner(reach: .noNetwork, collapsed: false) { _ in }
            ReachabilityBanner(reach: .serverDown, collapsed: false) { _ in }
            ReachabilityBanner(reach: .serverDown, collapsed: true) { _ in }
            Spacer()
        }
        .background(Zine.paper)
        try snap("reachability", model: model, size: CGSize(width: 393, height: 360), banners)
        // A find parked while offline, listed in the queue.
        _ = model.queue.queueFind(userId: "u-me", stickerId: SampleStickers.available.id, placeName: SampleStickers.available.placeName,
                                  at: Position(GeoPoint.lausanne, accuracyM: 8), photo: Data())
        try snap("sync-queue", model: model, SyncQueueSheet().background(Zine.panel))
        try snap("sync-banner", model: model, size: CGSize(width: 393, height: 120), PendingSyncBanner(queue: model.myQueue) {}.padding().background(Zine.paper))
    }

    func testOrderRules() {
        XCTAssertNotNil(try? orderBody(OrderDraft(mode: .post, quantity: "5", address: "Rue 1")).get())
        if case .failure(let e) = orderBody(OrderDraft(mode: .post, quantity: "0", address: "Rue 1")) { XCTAssertEqual(e.reason, .of("order_error_quantity", "100")) } else { XCTFail() }
        if case .failure(let e) = orderBody(OrderDraft(mode: .post, quantity: "5")) { XCTAssertEqual(e.reason, .of("order_error_address")) } else { XCTFail() }
        if case .failure(let e) = orderBody(OrderDraft(mode: .hand, quantity: "5")) { XCTAssertEqual(e.reason, .of("order_error_where")) } else { XCTFail() }
        let hand = try? orderBody(OrderDraft(mode: .hand, quantity: "3", address: "ignored", message: "Gare")).get()
        XCTAssertNil(hand?.address)
    }

    private func snap<V: View>(_ name: String, signedIn: Bool = false, size: CGSize? = nil, _ view: V) throws {
        let frame = CGRect(origin: .zero, size: size ?? phone)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let preview = AppModel.preview(signedIn: signedIn)
        let host = UIHostingController(rootView: view.environment(preview).environment(preview.location).tint(Zine.ink))
        if size != nil { host.safeAreaRegions = [] }
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = frame
        host.view.layoutIfNeeded()
        // Let SwiftUI lay out, load the images and settle the first animation frame.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let image = UIGraphicsImageRenderer(bounds: frame).image { _ in
            window.drawHierarchy(in: frame, afterScreenUpdates: true)
        }
        window.isHidden = true

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: url)
        }
    }

    func testWelcomeSlides() throws {
        for slide in WelcomeSlide.allCases {
            try snap("welcome-\(slide.rawValue)-\(slide)", WelcomeView(onLogin: {}, page: slide))
        }
    }

    func testLoginModes() throws {
        try snap("login-signin", NavigationStack { LoginView(model: LoginModel(mode: .login)) })
        try snap("login-register", NavigationStack { LoginView(model: LoginModel(mode: .register)) })
        try snap("login-forgot", NavigationStack { LoginView(model: LoginModel(mode: .forgot)) })
    }

    func testSignInError() async throws {
        let model = LoginModel(mode: .login)
        model.email = StubServer.email
        model.password = "wrong"
        await model.submit(AppModel.preview())
        XCTAssertEqual(model.error, .of("auth_error_credentials"))
        try snap("login-error", NavigationStack { LoginView(model: model) })
    }

    func testShortPasswordRule() async throws {
        let model = LoginModel(mode: .register)
        model.name = "Zoé"
        model.email = "zoe@example.com"
        model.password = "short"
        model.termsAccepted = true
        await model.submit(AppModel.preview())
        XCTAssertTrue(model.passwordRuleError)
        try snap("login-register-short-password", NavigationStack { LoginView(model: model) })
    }

    func testBirdSheets() throws {
        let cases: [(String, MapSticker)] = [
            ("available", SampleStickers.available),
            ("found", SampleStickers.found),
            ("mine", SampleStickers.mine),
            ("archived", SampleStickers.archived),
            ("wished", SampleStickers.wished),
        ]
        for (name, sticker) in cases {
            try snap("sheet-\(name)", signedIn: true, size: CGSize(width: 393, height: 520), StickerSheetView(sticker: sticker).background(Zine.panel))
        }
        try snap("sheet-gallery", signedIn: true, size: CGSize(width: 393, height: 420), StickerGallery(stickers: SampleStickers.all) { _ in }.background(Zine.paper))
    }

    func testPins() throws {
        let pins = VStack(spacing: 12) {
            ForEach(PinKind.allCases, id: \.self) { kind in
                HStack(spacing: 12) {
                    ForEach([PinStyle(kind), PinStyle(kind, wish: true), PinStyle(kind, reported: true), PinStyle(kind, isPrivate: true)], id: \.self) {
                        Image(uiImage: PinRenderer.image($0))
                    }
                }
            }
        }
        .padding(20)
        .background(Zine.paper)
        try snap("pins", size: CGSize(width: 260, height: 300), pins)
    }

    func testSplash() throws {
        try snap("splash", SplashView())
    }

    /// The pins are drawn once per style, and every style has its own sprite.
    func testEverySpriteRenders() {
        for style in PinStyle.all {
            let image = PinRenderer.image(style)
            XCTAssertEqual(image.size, CGSize(width: PinRenderer.width, height: PinRenderer.height), style.spriteId)
        }
    }

    /// Every string key the screens of this step use exists in the catalog.
    func testStringsResolve() {
        for key in ["brand_name", "welcome_hello_body", "welcome_page", "login_title", "sheet_placed_by", "reach_slim", "settings_sign_out_body"] {
            XCTAssertNotEqual(L(key), key, "missing string \(key)")
        }
        XCTAssertEqual(L("welcome_page", 2, 5), "Étape 2 sur 5")
        XCTAssertEqual(L("sheet_placed_by", "alice"), "Posé par alice")
    }

    /// Syne is bundled and found by name (UIAppFonts).
    func testTheFontIsLoaded() {
        XCTAssertNotNil(UIFont(name: "Syne-Regular", size: 12))
    }
}
