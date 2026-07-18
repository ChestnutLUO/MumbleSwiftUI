import Foundation
import MumbleConnection
import MumbleProtocol
import Observation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let senderName: String
    let text: String
    let date: Date
}

/// Bridges one MumbleSession to SwiftUI: connection lifecycle,
/// trust-on-first-use certificate pinning, live server state, chat,
/// and voice-receive playback.
@Observable @MainActor
final class SessionController {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .disconnected
    private(set) var serverState = MumbleServerState()
    private(set) var syncInfo: MumbleServerSyncInfo?
    private(set) var chat: [ChatMessage] = []
    private(set) var speakingSessions: Set<UInt32> = []

    private var session: MumbleSession?
    private var voice: VoiceReceiveController?
    private var eventTask: Task<Void, Never>?

    var ownUser: MumbleUser? {
        guard let id = syncInfo?.sessionID else { return nil }
        return serverState.users[id]
    }

    // MARK: - Connect / disconnect

    func connect(host: String, port: UInt16, username: String, password: String?) async {
        guard status != .connecting else { return }
        status = .connecting

        let pinKey = "pinnedCert.\(host):\(port)"
        let pinnedHash = UserDefaults.standard.data(forKey: pinKey)

        let trustPolicy: ServerTrustPolicy =
            pinnedHash.map { .pinnedCertificateSHA256($0) } ?? .insecureAcceptAny

        let configuration = MumbleSessionConfiguration(
            host: host,
            port: port,
            username: username,
            password: password?.isEmpty == true ? nil : password,
            trustPolicy: trustPolicy
        )
        let session = MumbleSession(configuration: configuration)
        self.session = session

        do {
            let info = try await session.connect()
            syncInfo = info
            serverState = await session.state

            // Trust on first use: remember this server's certificate.
            if pinnedHash == nil, let observed = await session.serverCertificateSHA256 {
                UserDefaults.standard.set(observed, forKey: pinKey)
            }

            let voice = VoiceReceiveController()
            if let cryptSetup = await session.cryptSetup {
                await voice.start(host: host, port: port, cryptSetup: cryptSetup) { [weak self] speaking in
                    Task { @MainActor in self?.speakingSessions = speaking }
                }
            }
            self.voice = voice

            status = .connected
            observeEvents(of: session)
        } catch let error as MumbleSessionError {
            status = .failed(Self.describe(error, pinExisted: pinnedHash != nil))
            self.session = nil
        } catch {
            status = .failed(
                pinnedHash != nil
                    ? "Connection failed — if the server was reinstalled, its certificate may have changed. (\(error.localizedDescription))"
                    : error.localizedDescription)
            self.session = nil
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        voice?.stop()
        voice = nil
        if let session {
            await session.disconnect()
        }
        session = nil
        syncInfo = nil
        chat = []
        speakingSessions = []
        serverState = MumbleServerState()
        status = .disconnected
    }

    // MARK: - Actions

    func joinChannel(_ channelID: UInt32) {
        guard let session else { return }
        Task {
            try? await session.joinChannel(channelID)
        }
    }

    func sendChat(_ text: String) {
        guard let session, !text.isEmpty else { return }
        let channelID = ownUser?.channelID ?? 0
        chat.append(
            ChatMessage(
                senderName: ownUser?.name ?? "me", text: text, date: Date()))
        Task {
            try? await session.sendTextMessage(text, toChannel: channelID)
        }
    }

    // MARK: - Events

    private func observeEvents(of session: MumbleSession) {
        eventTask = Task { [weak self] in
            for await event in await session.events {
                guard let self else { return }
                switch event {
                case .serverStateChanged(let state):
                    self.serverState = state
                case .textMessage(let message):
                    let sender = message.hasActor
                        ? self.serverState.users[message.actor]?.name ?? "user \(message.actor)"
                        : "server"
                    self.chat.append(
                        ChatMessage(senderName: sender, text: message.message, date: Date()))
                case .voiceTunnel(let datagram):
                    self.voice?.receiveTunneled(datagram)
                case .permissionDenied(let denied):
                    self.chat.append(
                        ChatMessage(
                            senderName: "server",
                            text: "Permission denied: \(denied.type)",
                            date: Date()))
                case .disconnected(let error):
                    self.status = .failed(error.map { $0.localizedDescription } ?? "Disconnected")
                    await self.disconnect()
                    return
                }
            }
        }
    }

    private static func describe(_ error: MumbleSessionError, pinExisted: Bool) -> String {
        switch error {
        case .rejected(_, let reason):
            "Server rejected the connection: \(reason)"
        case .timeout:
            "Connection timed out"
        case .connectionClosedDuringHandshake:
            pinExisted
                ? "Connection closed — the server's certificate may have changed since it was pinned."
                : "Connection closed during handshake"
        case .alreadyConnected:
            "Already connected"
        }
    }
}
