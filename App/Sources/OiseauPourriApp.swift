import SwiftUI
import OiseauCore

@main
struct OiseauPourriApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundSync.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.location)
                .task { await model.start() }
                .onOpenURL { model.open($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.open(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.resumed() } }
            if phase == .background { BackgroundSync.schedule() }
        }
    }
}

/// Which part of the app the player is in, from the session (Android: OiseauRoot).
struct RootView: View {
    @Environment(AppModel.self) private var model

    init() {}

    var body: some View {
        Group {
            switch model.session {
            case .unknown: SplashView()
            case .signedOut: SignedOutFlow()
            case .signedIn: AuthedShell().firstRunGates()
            }
        }
        .tint(Zine.ink)
        .preferredColorScheme(.light) // Zine is one light look (spec §14)
    }
}

/// The launch screen while the stored session is read (usually a blink).
struct SplashView: View {
    var body: some View {
        ZStack {
            Zine.pink.ignoresSafeArea()
            Mascotte(.photo, label: L("brand_mascot"))
                .frame(width: 150, height: 150)
                .clipShape(Circle())
                .overlay(Circle().stroke(Zine.ink, lineWidth: 4))
        }
    }
}
