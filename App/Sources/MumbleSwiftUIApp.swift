import SwiftUI

@main
struct MumbleSwiftUIApp: App {
    @State private var controller = SessionController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
        }
    }
}

struct ContentView: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        switch controller.status {
        case .connected:
            SessionView()
        case .disconnected, .connecting, .failed:
            ServerConnectView()
        }
    }
}
