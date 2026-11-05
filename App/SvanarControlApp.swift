import SwiftUI

@main
@MainActor
struct SvanarControlApp: App {
    @StateObject private var headphones = HeadphoneManager()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(headphones)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { phase in headphones.setForeground(phase == .active) }
        }
    }
}
