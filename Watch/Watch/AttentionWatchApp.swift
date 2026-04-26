import SwiftUI

@main
struct AttentionWatchApp: App {
    @StateObject private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(session)
                .task {
                    session.activate()
                }
                .onOpenURL { url in
                    // Complication tap deep-links here — fire the press without a second tap.
                    if url.scheme == "attention", url.host == "press" {
                        session.sendPress()
                    }
                }
        }
    }
}
