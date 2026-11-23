import XCTest

/// The one journey of this step, in the real app against the in-memory stub API
/// (`-stubApi`): welcome → sign-in → the map → a bird's sheet → sign out.
/// Screenshots go to TEST_RUNNER_SCREENSHOT_DIR when CI sets it.
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-stubApi", "-resetState"]
        app.launch()
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("ui-\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    /// iOS offers to save the password after a sign-in: decline, it covers the map.
    private func dismissSavePassword() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Not Now", "Pas maintenant"] {
            for target in [app.buttons[label], springboard.buttons[label]] where target.waitForExistence(timeout: 4) {
                target.tap()
                return
            }
        }
    }

    /// Scrolls until [element] can be tapped (the forms are in scroll views).
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
    }

    func testSignInReachesTheMapAndABird() {
        XCTAssertTrue(app.buttons["welcome.next"].waitForExistence(timeout: 15), "the welcome carousel opens for a new player")
        shot("01-welcome")
        app.buttons["welcome.next"].tap()
        shot("02-welcome-search")
        app.buttons["welcome.skip"].tap()
        let toLogin = app.buttons["welcome.toLogin"]
        XCTAssertTrue(toLogin.waitForExistence(timeout: 5))
        shot("03-signup")
        reveal(toLogin)
        toLogin.tap()

        let email = app.textFields["login.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("alice@example.com")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("wrong-password")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.staticTexts["login.error"].waitForExistence(timeout: 10), "a wrong password is refused")
        shot("04-login-error")

        // A secure field empties itself when typing starts again; the deletes make sure.
        password.tap()
        password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "password123")
        app.buttons["login.submit"].tap()

        let map = app.otherElements["map"]
        XCTAssertTrue(map.waitForExistence(timeout: 20), "signed in, the map shows")
        dismissSavePassword()
        // Give the OpenFreeMap tiles a moment.
        sleep(6)
        shot("05-map")

        // The stub's « Fontaine du Bourg » sits exactly where the map opens: its pin
        // stands just above the centre of the screen.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -24)).tap()
        let title = app.staticTexts["Fontaine du Bourg"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "tapping a pin opens its sheet")
        shot("06-sheet")

        XCTAssertTrue(app.buttons["sheet.find"].exists, "a bird to hunt offers « Trouver »")
        app.buttons["sheet.find"].tap()
        XCTAssertTrue(app.buttons["hunt.submit"].waitForExistence(timeout: 5), "the find sheet opens")
        shot("07-find")
        app.buttons["Fermer"].firstMatch.tap()

        // Each tab opens.
        for (tab, name) in [("Collection", "08-collection"), ("Classement", "09-leaderboard"), ("Poser", "10-place"), ("Profil", "11-profile")] {
            app.tabBars.buttons[tab].tap()
            sleep(2)
            shot(name)
        }

        // Sign out from Réglages.
        app.buttons["profile.settings"].tap()
        let signOut = app.buttons["settings.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        shot("12-settings")
        signOut.tap()
        // An action sheet or, on iOS 26, an alert: the confirm is the other « Se déconnecter ».
        let confirm = app.buttons
            .matching(NSPredicate(format: "label == %@ AND identifier != %@", "Se déconnecter", "settings.signOut"))
            .firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("13-sign-out")
        confirm.tap()
        XCTAssertTrue(app.buttons["welcome.next"].waitForExistence(timeout: 10), "signed out, back to the welcome")
    }
}
