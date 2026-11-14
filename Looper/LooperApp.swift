import SwiftUI

@main
struct LooperApp: App {
    var body: some Scene {
        WindowGroup("Looper") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
