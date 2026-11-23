import PhotosUI
import SwiftUI
import OiseauCore

/// Réglages ▸ Compte et sécurité (Android: ui/settings/AccountScreen.kt, AccountViewModel.kt):
/// the profile (name, picture), the e-mail, the password, my data, deleting the account.
struct AccountScreen: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var avatar: Data?
    @State private var avatarItem: PhotosPickerItem?
    @State private var newEmail = ""
    @State private var emailPassword = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var deletePassword = ""
    @State private var confirmDelete = false
    @State private var busy: String?
    @State private var outcome: [String: (UiText, Bool)] = [:]
    @State private var export: URL?

    init() {}

    var body: some View {
        let user = app.session.user
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                group(L("account_profile"), key: "profile") {
                    HStack(spacing: 14) {
                        Group {
                            if let avatar, let image = UIImage(data: avatar) {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(Circle())
                            } else {
                                Avatar(image: user?.image, size: 72)
                            }
                        }
                        .overlay(Circle().stroke(Zine.ink, lineWidth: 3))
                        PhotosPicker(selection: $avatarItem, matching: .images) {
                            Text(L("account_change_avatar")).font(.syne(14, 700)).underline().foregroundStyle(Zine.ink)
                        }
                    }
                    OpTextField(label: L("login_name"), text: $name, kind: .name)
                    OpButton(title: busy == "profile" ? "…" : L("edit_save"), fullWidth: true) {
                        run("profile", saved: "account_profile_saved") {
                            try await app.account.updateProfile(name: name.trimmingCharacters(in: .whitespaces), avatar: avatar)
                        }
                    }
                    .disabled(busy != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                group(L("account_email"), key: "email") {
                    if let user {
                        Text(L(user.emailVerified ? "account_email_verified" : "account_email_unverified", user.email)).font(.zBody).foregroundStyle(Zine.muted)
                        if !user.emailVerified {
                            OpButton(title: L("account_resend"), variant: .secondary, fullWidth: true) {
                                run("email", saved: "account_verification_sent") { try await app.account.resendVerification(email: user.email) }
                            }
                            .disabled(busy != nil)
                        }
                    }
                    OpTextField(label: L("account_new_email"), text: $newEmail, kind: .email)
                    OpTextField(label: L("account_current_password"), text: $emailPassword, kind: .password)
                    OpButton(title: busy == "email" ? "…" : L("account_change_email"), fullWidth: true) {
                        let verified = user?.emailVerified == true
                        run("email", saved: verified ? "account_email_requested_verified" : "account_email_requested") {
                            try await app.account.changeEmail(newEmail, currentPassword: emailPassword)
                            emailPassword = ""
                        }
                    }
                    .disabled(busy != nil || newEmail.isEmpty || emailPassword.isEmpty)
                }

                group(L("login_password"), key: "password") {
                    OpTextField(label: L("account_current_password"), text: $currentPassword, kind: .password)
                    OpTextField(label: L("account_new_password"), text: $newPassword, kind: .newPassword,
                                supporting: !newPassword.isEmpty && newPassword.count < LoginModel.minPassword ? L("login_password_hint") : nil,
                                isError: !newPassword.isEmpty && newPassword.count < LoginModel.minPassword)
                    OpButton(title: busy == "password" ? "…" : L("account_change_password"), fullWidth: true) {
                        run("password", saved: "account_password_saved") {
                            try await app.account.changePassword(current: currentPassword, new: newPassword)
                            currentPassword = ""
                            newPassword = ""
                        }
                    }
                    .disabled(busy != nil || currentPassword.isEmpty || newPassword.count < LoginModel.minPassword)
                }

                group(L("account_data"), key: "export") {
                    Text(L("account_data_help")).font(.zBody).foregroundStyle(Zine.muted)
                    OpButton(title: L(busy == "export" ? "account_export_busy" : "account_export"), icon: "download", variant: .secondary, fullWidth: true) {
                        run("export", saved: nil, fallback: "account_export_failed") {
                            let data = try await app.account.export()
                            let day = Date().formatted(.iso8601.year().month().day())
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(L("account_export_file", day))
                            try data.write(to: url)
                            export = url
                        }
                    }
                    .disabled(busy != nil)
                    if let export {
                        // The share sheet: save to Files, AirDrop, mail…
                        ShareLink(item: export) {
                            Label { Text(L("account_export_saved")).font(.syne(14, 700)) } icon: { LucideIcon("external_link", size: 16) }
                        }
                        .foregroundStyle(Zine.ink)
                    }
                }

                group(L("account_danger"), key: "delete") {
                    Text(L("account_danger_help")).font(.zBody).foregroundStyle(Zine.muted)
                    OpButton(title: L("account_delete"), icon: "trash_2", variant: .danger, fullWidth: true) { confirmDelete = true }
                        .disabled(busy != nil)
                }
            }
            .padding(16)
            .padding(.trailing, Zine.pressOffset)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Zine.paper)
        .navigationTitle(L("settings_account"))
        .onAppear {
            if name.isEmpty { name = user?.name ?? "" }
            if let landing = app.accountLanding {
                app.accountLanding = nil
                if landing.failed {
                    outcome["email"] = (.of("auth_error_link"), false)
                } else if let l = landing.landed {
                    outcome["email"] = (.of(l == .verified ? "account_email_landed_verified" : "account_email_landed_approved"), true)
                }
            }
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { avatar = await app.photoPreparer.prepare(data) }
                avatarItem = nil
            }
        }
        .sheet(isPresented: $confirmDelete) { deleteSheet }
    }

    private var deleteSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("account_delete_intro")).font(.zBody)
                    ForEach(0..<4, id: \.self) { i in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                            Text(L("account_delete_items.\(i)")).font(.zBody)
                        }
                    }
                    Text(L("account_delete_birds")).font(.zBody).foregroundStyle(Zine.muted)
                    OpTextField(label: L("account_delete_password"), text: $deletePassword, kind: .password)
                    if let o = outcome["delete"], !o.1 { Text(o.0.text).font(.zBody).foregroundStyle(Zine.error) }
                    OpButton(title: L(busy == "delete" ? "account_delete_busy" : "account_delete_confirm"), variant: .danger, fullWidth: true) {
                        guard let id = app.session.user?.id else { return }
                        run("delete", saved: nil, fallback: "account_delete_failed") {
                            try await app.account.deleteAccount(password: deletePassword, userId: id)
                        }
                    }
                    .disabled(busy != nil || deletePassword.isEmpty)
                }
                .foregroundStyle(Zine.ink)
                .padding(20)
            }
            .navigationTitle(L("account_delete_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("common_cancel")) { confirmDelete = false } } }
        }
        .tint(Zine.ink)
        .presentationDetents([.large])
    }

    /// A titled block with its outcome line under it.
    private func group<Content: View>(_ title: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: title)
            content()
            if let o = outcome[key] {
                Text(o.0.text).font(.zBody).foregroundStyle(o.1 ? Zine.found : Zine.error)
            }
        }
    }

    private func run(_ key: String, saved: String?, fallback: String = "account_failed", _ block: @escaping () async throws -> Void) {
        busy = key
        outcome[key] = nil
        Task {
            do {
                try await block()
                if let saved { outcome[key] = (.of(saved), true) }
            } catch let e as ApiError {
                outcome[key] = (authErrorMessage(e, fallback: fallback), false)
            } catch {
                outcome[key] = (.of(fallback), false)
            }
            busy = nil
        }
    }
}
