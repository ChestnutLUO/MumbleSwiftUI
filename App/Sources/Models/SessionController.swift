import AVFoundation
import Foundation
import MumbleConnection
import MumbleProtocol
import Observation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let senderName: String
    let text: String
    let date: Date
    /// Non-nil for private (user-to-user) messages: who the exchange is with.
    var privateWith: String?
}

/// Bridges one MumbleSession to SwiftUI: connection lifecycle,
/// trust-on-first-use certificate pinning, live server state, chat,
/// and two-way voice.
@Observable @MainActor
final class SessionController {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// Target of outgoing chat: the current channel, or one user.
    enum ChatTarget: Equatable {
        case currentChannel
        case user(sessionID: UInt32, name: String)
    }

    private(set) var status: Status = .disconnected
    private(set) var serverState = MumbleServerState()
    private(set) var syncInfo: MumbleServerSyncInfo?
    private(set) var chat: [ChatMessage] = []
    private(set) var speakingSessions: Set<UInt32> = []
    private(set) var locallyMuted: Set<UInt32> = []

    // Self voice state.
    private(set) var selfMuted = false
    private(set) var selfDeafened = false
    private(set) var transmitting = false
    private(set) var inputLevelDB: Float = -100
    var chatTarget: ChatTarget = .currentChannel

    private var session: MumbleSession?
    private var voice: VoiceController?
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

            await startVoice(session: session, host: host, port: port)

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

    private func startVoice(session: MumbleSession, host: String, port: UInt16) async {
        guard let cryptSetup = await session.cryptSetup else { return }

        // Transmit needs the mic; a denial leaves the session receive-only.
        _ = await AVCaptureDevice.requestAccess(for: .audio)

        let voice = VoiceController(settings: AudioPreferences.load())
        await voice.start(
            host: host,
            port: port,
            cryptSetup: cryptSetup,
            sendTunnel: { datagram in
                try? await session.sendVoiceTunnel(datagram)
            },
            requestCryptResync: {
                try? await session.requestCryptResync()
            },
            onSpeakingChanged: { [weak self] speaking in
                Task { @MainActor in self?.speakingSessions = speaking }
            },
            onSelfActivity: { [weak self] level, transmitting in
                Task { @MainActor in
                    self?.inputLevelDB = level
                    self?.transmitting = transmitting
                }
            }
        )
        self.voice = voice
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
        locallyMuted = []
        selfMuted = false
        selfDeafened = false
        transmitting = false
        chatTarget = .currentChannel
        serverState = MumbleServerState()
        status = .disconnected
    }

    // MARK: - Voice controls

    func toggleSelfMute() {
        // Unmuting also undeafens (you can't stay deafened while unmuted).
        selfMuted
            ? setSelf(muted: false, deafened: false)
            : setSelf(muted: true, deafened: selfDeafened)
    }

    func toggleSelfDeafen() {
        setSelf(muted: selfMuted, deafened: !selfDeafened)
    }

    private func setSelf(muted: Bool, deafened: Bool) {
        // Deafen implies mute; undeafening restores unmuted (upstream UX).
        let muted = muted || deafened
        selfMuted = muted
        selfDeafened = deafened
        guard let session, let voice else { return }
        Task {
            await voice.setTransmitMuted(muted)
            await voice.setDeafened(deafened)
            try? await session.setSelfMute(muted, deafen: deafened)
        }
    }

    func setPTTPressed(_ pressed: Bool) {
        guard let voice else { return }
        Task { await voice.setPTTPressed(pressed) }
    }

    func setLocalMute(_ sessionID: UInt32, muted: Bool) {
        if muted {
            locallyMuted.insert(sessionID)
        } else {
            locallyMuted.remove(sessionID)
        }
        guard let voice else { return }
        Task { await voice.setLocalMute(sessionID, muted: muted) }
    }

    func applyAudioPreferences() {
        guard let voice else { return }
        let settings = AudioPreferences.load()
        Task { await voice.apply(settings) }
    }

    // MARK: - Actions

    func joinChannel(_ channelID: UInt32) {
        guard let session else { return }
        Task {
            try? await session.joinChannel(channelID)
        }
    }

    func createChannel(name: String, parentID: UInt32) {
        guard let session, !name.isEmpty else { return }
        Task {
            try? await session.createChannel(name: name, parentID: parentID)
        }
    }

    func sendChat(_ text: String) {
        guard let session, !text.isEmpty else { return }
        let me = ownUser?.name ?? "me"
        switch chatTarget {
        case .currentChannel:
            let channelID = ownUser?.channelID ?? 0
            chat.append(ChatMessage(senderName: me, text: text, date: Date()))
            Task {
                try? await session.sendTextMessage(text, toChannel: channelID)
            }
        case .user(let sessionID, let name):
            chat.append(
                ChatMessage(senderName: me, text: text, date: Date(), privateWith: name))
            Task {
                try? await session.sendPrivateMessage(text, toUser: sessionID)
            }
        }
    }

    func startPrivateChat(with user: MumbleUser) {
        chatTarget = .user(sessionID: user.id, name: user.name)
    }

    // MARK: - Events

    private func observeEvents(of session: MumbleSession) {
        eventTask = Task { [weak self] in
            for await event in await session.events {
                guard let self else { return }
                switch event {
                case .serverStateChanged(let state):
                    self.serverState = state
                    self.reflectOwnUserState()
                case .textMessage(let message):
                    self.receiveText(message)
                case .voiceTunnel(let datagram):
                    self.voice?.receiveTunneled(datagram)
                case .cryptSetupChanged(let cryptSetup):
                    if let voice = self.voice {
                        Task { await voice.updateCrypt(cryptSetup) }
                    }
                case .permissionDenied(let denied):
                    self.chat.append(
                        ChatMessage(
                            senderName: "server",
                            text: "Permission denied: \(Self.describe(denied))",
                            date: Date()))
                case .disconnected(let error):
                    self.status = .failed(error.map { $0.localizedDescription } ?? "Disconnected")
                    await self.disconnect()
                    return
                }
            }
        }
    }

    private func receiveText(_ message: MumbleProto_TextMessage) {
        let sender = message.hasActor
            ? serverState.users[message.actor]?.name ?? "user \(message.actor)"
            : "server"
        // A message addressed to our session (not a channel) is private.
        let isPrivate = !message.session.isEmpty && message.channelID.isEmpty
            && message.treeID.isEmpty
        chat.append(
            ChatMessage(
                senderName: sender,
                text: message.message,
                date: Date(),
                privateWith: isPrivate ? sender : nil))
    }

    /// Mirrors server-echoed self mute/deafen (e.g. changed by an admin).
    private func reflectOwnUserState() {
        guard let own = ownUser else { return }
        if own.isSelfMuted != selfMuted || own.isSelfDeafened != selfDeafened {
            selfMuted = own.isSelfMuted
            selfDeafened = own.isSelfDeafened
            guard let voice else { return }
            Task {
                await voice.setTransmitMuted(own.isSelfMuted || own.isMuted)
                await voice.setDeafened(own.isSelfDeafened)
            }
        }
    }

    private static func describe(_ denied: MumbleProto_PermissionDenied) -> String {
        switch denied.type {
        case .permission: "insufficient permission"
        case .channelName: "invalid channel name"
        case .textTooLong: "message too long"
        case .temporaryChannel: "not allowed from a temporary channel"
        case .channelFull: "channel is full"
        default: "\(denied.type)"
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

/// Audio preferences persisted in UserDefaults (edited by the settings UI).
enum AudioPreferences {
    static let modeKey = "audio.transmitMode"
    static let bitrateKey = "audio.bitrate"
    static let vadThresholdKey = "audio.vadThresholdDB"

    static func load() -> VoiceSettings {
        let defaults = UserDefaults.standard
        var settings = VoiceSettings()
        if let raw = defaults.string(forKey: modeKey), let mode = TransmitMode(rawValue: raw) {
            settings.mode = mode
        }
        let bitrate = defaults.integer(forKey: bitrateKey)
        if bitrate > 0 {
            settings.bitrate = bitrate
        }
        if defaults.object(forKey: vadThresholdKey) != nil {
            settings.vadOpenThresholdDB = defaults.float(forKey: vadThresholdKey)
        }
        return settings
    }
}
