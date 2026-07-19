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
        Group {
            switch controller.status {
            case .connected:
                SessionView()
            case .disconnected, .connecting, .failed:
                ServerConnectView()
            }
        }
        #if DEBUG
            // UI-test hook: `--autoconnect` connects with the saved
            // server details on launch (used by simulator smoke tests).
            .task {
                guard CommandLine.arguments.contains("--autoconnect"),
                    controller.status == .disconnected
                else { return }
                let defaults = UserDefaults.standard
                await controller.connect(
                    host: defaults.string(forKey: "lastHost") ?? "127.0.0.1",
                    port: UInt16(defaults.string(forKey: "lastPort") ?? "") ?? 64738,
                    username: defaults.string(forKey: "lastUsername") ?? "ui-test",
                    password: nil)
            }
        #endif
    }
}
