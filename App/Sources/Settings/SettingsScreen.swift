import SwiftUI
import OiseauCore

/// Réglages (Android: ui/settings/SettingsScreen.kt): the menu of sub-pages, Ko-fi,
/// the sign-out, the legal pages and the version. On iOS: a grouped list, the
/// system's own settings look.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var confirmSignOut = false

    init() {}

    private static let kofi = URL(string: "https://ko-fi.com/M5M621GX8W")!

    var body: some View {
        List {
            Section {
                row(.account, icon: "shield_check", title: "settings_account", hint: "settings_account_hint")
                row(.order, icon: "package", title: "settings_order", hint: "settings_order_hint")
                row(.preferences, icon: "sliders_horizontal", title: "settings_preferences", hint: "settings_preferences_hint")
                row(.offlineMaps, icon: "map", title: "offline_maps_title", hint: "offline_maps_hint")
                if app.session.user?.isAdmin == true {
                    Button { openURL(AppConfig.webBaseURL.appendingPathComponent("settings/admin")) } label: {
                        SettingsLabel(icon: "wrench", title: L("settings_admin"), hint: L("settings_admin_hint"))
                    }
                }
            }
            Section {
                Button { openURL(Self.kofi) } label: {
                    HStack {
                        SettingsLabel(icon: "coffee", title: L("settings_kofi"), hint: L("settings_kofi_hint"), tint: Color(hex: 0xF57373))
                        Spacer()
                        LucideIcon("external_link", size: 16).foregroundStyle(Zine.muted)
                    }
                }
            }
            Section {
                Button(role: .destructive) { confirmSignOut = true } label: {
                    HStack(spacing: 12) {
                        LucideIcon("log_out", size: 20)
                        Text(L("settings_sign_out")).font(.zTitle)
                    }
                }
                .accessibilityIdentifier("settings.signOut")
            } footer: {
                VStack(spacing: 4) {
                    LegalLinks()
                    Text(L("settings_version", appVersion, appBuild)).font(.zBodySmall).foregroundStyle(Zine.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Zine.paper)
        .navigationTitle(L("settings_title"))
        .confirmationDialog(L("settings_sign_out_title"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(L("settings_sign_out"), role: .destructive) { Task { await app.signOut() } }
                .accessibilityIdentifier("settings.confirmSignOut")
            Button(L("common_cancel"), role: .cancel) {}
        } message: {
            let pending = app.pendingCount
            Text(L("settings_sign_out_body") + (pending > 0 ? "\n\n" + L("settings_sign_out_pending", pending) : ""))
        }
    }

    private func row(_ route: Route, icon: String, title: String, hint: String) -> some View {
        NavigationLink(value: route) {
            SettingsLabel(icon: icon, title: L(title), hint: L(hint))
        }
    }

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var appBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
}

/// A settings row: Lucide icon, title, the hint under it.
struct SettingsLabel: View {
    let icon: String
    let title: String
    var hint: String?
    var tint: Color = Zine.ink

    var body: some View {
        HStack(spacing: 12) {
            LucideIcon(icon, size: 20).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.zTitle).foregroundStyle(Zine.ink)
                if let hint { Text(hint).font(.zBodySmall).foregroundStyle(Zine.muted) }
            }
        }
        .padding(.vertical, 4)
    }
}
