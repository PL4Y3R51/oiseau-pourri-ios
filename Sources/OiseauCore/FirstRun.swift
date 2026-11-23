import Foundation

// The blocking popups of a signed-in launch (Android: domain/FirstRun.kt; web: AuthedApp.tsx).

/// Version tag of the current CGU + privacy policy — mirror of `CURRENT_TERMS_VERSION`
/// in packages/shared. Bump both together.
public let currentTermsVersion = "2026-07-05"

/// One at a time: terms acceptance, then "Quoi de neuf".
public enum FirstRunGate: Sendable { case terms, releaseNotes }

/// Which gate to show; nil = none, the app is usable.
///
/// No onboarding popup: every signed-out visitor swipes through the welcome carousel
/// before signing in, so the app marks the account onboarded instead
/// ([shouldMarkOnboarded]) — and the web doesn't repeat it.
///
/// The release notes are skipped on purpose for a device that has never seen any
/// (first install) and for an account not yet onboarded: nothing is "new" to someone
/// who just arrived — the caller then marks the latest as seen.
public func firstRunGate(_ prefs: UserPrefs, lastSeenRelease: String?, latestRelease: String) -> FirstRunGate? {
    if prefs.termsAcceptedVersion != currentTermsVersion { return .terms }
    if let last = lastSeenRelease, last != latestRelease { return .releaseNotes }
    return nil
}

/// The account hasn't been through the welcome yet: the carousel stood in for it.
public func shouldMarkOnboarded(_ prefs: UserPrefs) -> Bool { !prefs.onboarded }

/// True when the latest notes should be recorded as seen without being shown.
public func shouldSilentlyMarkReleaseSeen(_ prefs: UserPrefs, lastSeenRelease: String?, latestRelease: String) -> Bool {
    lastSeenRelease != latestRelease && (lastSeenRelease == nil || !prefs.onboarded)
}

/// One entry of the app's own changelog; its texts are string keys (a title, and an
/// array of items: the Android `string-array`).
public struct Release: Hashable, Sendable {
    public var version: String
    public var date: String
    public var titleKey: String
    public var itemsKey: String

    public init(version: String, date: String, titleKey: String, itemsKey: String) {
        self.version = version
        self.date = date
        self.titleKey = titleKey
        self.itemsKey = itemsKey
    }
}

/// Newest first. For now the Android app's (ANDROID_RELEASES), whose texts the
/// strings sync brings; the iOS app gets its own entries once it ships.
public let appReleases: [Release] = [
    Release(version: "0.3", date: "2026-11-16", titleKey: "release_0_3_title", itemsKey: "release_0_3_items"),
    Release(version: "0.2", date: "2026-10-09", titleKey: "release_0_2_title", itemsKey: "release_0_2_items"),
    Release(version: "0.1", date: "2026-10-01", titleKey: "release_0_1_title", itemsKey: "release_0_1_items"),
]
