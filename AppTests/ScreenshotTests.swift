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

    private func snap<V: View>(_ name: String, signedIn: Bool = false, size: CGSize? = nil, _ view: V) throws {
        let frame = CGRect(origin: .zero, size: size ?? phone)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let host = UIHostingController(rootView: view.environment(AppModel.preview(signedIn: signedIn)).tint(Zine.ink))
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
