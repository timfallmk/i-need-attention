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
        }
    }
}
