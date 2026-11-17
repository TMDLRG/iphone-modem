import SwiftUI

@main
struct ModemApp: App {
    @StateObject private var controller = TetherController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.appBecameActive()
            }
        }
    }
}
