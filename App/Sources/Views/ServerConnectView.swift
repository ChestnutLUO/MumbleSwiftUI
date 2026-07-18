import SwiftUI

struct ServerConnectView: View {
    @Environment(SessionController.self) private var controller

    @AppStorage("lastHost") private var host = "127.0.0.1"
    @AppStorage("lastPort") private var portText = "64738"
    @AppStorage("lastUsername") private var username = ""
    @State private var password = ""

    private var port: UInt16? { UInt16(portText) }
    private var canConnect: Bool {
        !host.isEmpty && port != nil && !username.isEmpty
            && controller.status != .connecting
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Mumble")
                    .font(.largeTitle.bold())
            }

            Form {
                TextField("Server", text: $host, prompt: Text("mumble.example.com"))
                TextField("Port", text: $portText)
                TextField("Username", text: $username)
                SecureField("Password (optional)", text: $password)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 380)
            .onSubmit { if canConnect { connect() } }

            if case .failed(let message) = controller.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: 380)
            }

            Button(action: connect) {
                if controller.status == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                        .frame(minWidth: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConnect)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 520)
    }

    private func connect() {
        guard let port else { return }
        let host = host, username = username, password = password
        Task {
            await controller.connect(
                host: host, port: port, username: username, password: password)
        }
    }
}
