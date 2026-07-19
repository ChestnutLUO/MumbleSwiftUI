import Foundation
import MumbleAudio
import MumbleConnection
import MumbleProtocol

#if os(iOS)
    import AVFAudio
#endif

enum TransmitMode: String, CaseIterable, Identifiable {
    case continuous
    case voiceActivity
    case pushToTalk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuous: "Continuous"
        case .voiceActivity: "Voice Activity"
        case .pushToTalk: "Push to Talk"
        }
    }
}

struct VoiceSettings: Sendable {
    var mode: TransmitMode = .voiceActivity
    var bitrate: Int = 64_000
    var vadOpenThresholdDB: Float = -36
}

/// Owns the voice channel in both directions.
///
/// Receive: incoming `Audio` packets feed per-speaker jitter buffers and a
/// pump task keeps each speaker's playback ring topped up.
///
/// Transmit: mic frames are gated (continuous/VAD/PTT), Opus-encoded, and
/// sent over encrypted UDP — or through the TCP `UDPTunnel` while UDP is
/// unhealthy. UDP health is probed with encrypted pings; going unhealthy
/// also requests a crypt resync in case the OCB2 state desynced.
actor VoiceController {
    // MARK: Receive
    private var transport: MumbleUDPVoiceTransport?
    private var pipelines: [UInt32: SpeakerPipeline] = [:]
    private let output = VoiceAudioOutput()
    private var receiveTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var onSpeakingChanged: (@Sendable (Set<UInt32>) -> Void)?
    private var speaking: Set<UInt32> = []
    private var localMuted: Set<UInt32> = []
    private var deafened = false

    // MARK: Transmit
    private var input: VoiceAudioInput?
    private var transmitPipeline: VoiceTransmitPipeline?
    private var vad: VoiceActivityDetector
    private var settings: VoiceSettings
    private var pttPressed = false
    private var transmitMuted = false
    private var captureTask: Task<Void, Never>?
    private var onSelfActivity: (@Sendable (Float, Bool) -> Void)?

    // MARK: UDP health / tunnel fallback
    private var udpHealthy = false
    private var lastPong = Date.distantPast
    private var udpPingTask: Task<Void, Never>?
    private var sendTunnel: (@Sendable (Data) async -> Void)?
    private var requestCryptResync: (@Sendable () async -> Void)?

    /// Playback ring target: 100ms ahead of the render head.
    private static let targetBufferedSamples = MumbleAudioConstants.sampleRate / 10
    /// UDP is considered dead after this long without a ping reply.
    private static let udpTimeout: TimeInterval = 8

    init(settings: VoiceSettings = VoiceSettings()) {
        self.settings = settings
        vad = VoiceActivityDetector(openThresholdDB: settings.vadOpenThresholdDB)
    }

    func start(
        host: String,
        port: UInt16,
        cryptSetup: MumbleProto_CryptSetup,
        sendTunnel: @escaping @Sendable (Data) async -> Void,
        requestCryptResync: @escaping @Sendable () async -> Void,
        onSpeakingChanged: @escaping @Sendable (Set<UInt32>) -> Void,
        onSelfActivity: @escaping @Sendable (Float, Bool) -> Void
    ) async {
        self.sendTunnel = sendTunnel
        self.requestCryptResync = requestCryptResync
        self.onSpeakingChanged = onSpeakingChanged
        self.onSelfActivity = onSelfActivity

        #if os(iOS)
            // Mic + speaker simultaneously; voiceChat mode enables the
            // system echo canceller and routes to the receiver/speaker.
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP])
            try? audioSession.setActive(true)
        #endif

        do {
            try output.start()
        } catch {
            // No output device (e.g. CI) — playback is silently disabled.
        }

        if let transport = MumbleUDPVoiceTransport(
            host: host, port: port, cryptSetup: cryptSetup)
        {
            self.transport = transport
            do {
                try await transport.open()
                receiveTask = Task { [weak self] in
                    for await packet in transport.incoming {
                        guard let self else { return }
                        switch packet {
                        case .audio(let audio): await self.handle(audio)
                        case .ping: await self.notePong()
                        }
                    }
                }
                startUDPPingLoop()
            } catch {
                self.transport = nil
            }
        }

        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pump()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        startCapture()
    }

    // MARK: - Transmit controls

    func setPTTPressed(_ pressed: Bool) {
        pttPressed = pressed
    }

    /// Stops transmit while self-muted or self-deafened.
    func setTransmitMuted(_ muted: Bool) {
        transmitMuted = muted
    }

    /// Deafened: drop all incoming voice (and the server won't count on
    /// us hearing anything).
    func setDeafened(_ deafened: Bool) {
        self.deafened = deafened
    }

    func setLocalMute(_ sessionID: UInt32, muted: Bool) {
        if muted {
            localMuted.insert(sessionID)
            pipelines.removeValue(forKey: sessionID)
            output.removeSpeaker(sessionID)
        } else {
            localMuted.remove(sessionID)
        }
    }

    func isLocallyMuted(_ sessionID: UInt32) -> Bool {
        localMuted.contains(sessionID)
    }

    func apply(_ settings: VoiceSettings) {
        self.settings = settings
        vad.openThresholdDB = settings.vadOpenThresholdDB
        vad.closeThresholdDB = settings.vadOpenThresholdDB - 6
        transmitPipeline?.setBitrate(settings.bitrate)
    }

    /// Applies a CryptSetup update (resync nonce or key replacement).
    func updateCrypt(_ cryptSetup: MumbleProto_CryptSetup) {
        guard let transport else { return }
        if cryptSetup.hasServerNonce {
            transport.applyServerNonce(cryptSetup.serverNonce)
        }
    }

    /// Voice arriving through the TCP `UDPTunnel` fallback.
    nonisolated func receiveTunneled(_ datagram: Data) {
        guard case .audio(let audio)? = MumbleUDPVoiceTransport.decodePlaintext(datagram)
        else { return }
        Task { await self.handle(audio) }
    }

    nonisolated func stop() {
        Task { await self.shutdown() }
    }

    // MARK: - Capture / transmit path

    private func startCapture() {
        let input = VoiceAudioInput()
        guard let frames = try? input.start() else {
            // No microphone (or permission denied) — receive-only session.
            return
        }
        self.input = input
        transmitPipeline = try? VoiceTransmitPipeline(bitrate: settings.bitrate)

        captureTask = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.processCaptured(frame)
            }
        }
    }

    private func processCaptured(_ frame: [Float]) async {
        guard let pipeline = transmitPipeline else { return }

        let levelDB = VoiceActivityDetector.rmsDBFS(frame)
        let vadOpen = vad.process(levelDB: levelDB)
        let gate: Bool
        switch settings.mode {
        case .continuous: gate = true
        case .voiceActivity: gate = vadOpen
        case .pushToTalk: gate = pttPressed
        }
        let transmitting = gate && !transmitMuted && !deafened

        if transmitting {
            if let packets = try? pipeline.encode(frame) {
                for packet in packets {
                    await sendVoice(packet)
                }
            }
        } else if let terminator = try? pipeline.endTransmission() {
            await sendVoice(terminator)
        }
        onSelfActivity?(levelDB, transmitting)
    }

    private func sendVoice(_ audio: MumbleUDP_Audio) async {
        if udpHealthy, let transport {
            do {
                try await transport.send(.audio(audio))
                return
            } catch {
                udpHealthy = false
            }
        }
        guard let datagram = try? MumbleUDPVoiceTransport.encodePlaintext(.audio(audio))
        else { return }
        await sendTunnel?(datagram)
    }

    // MARK: - UDP health

    private func startUDPPingLoop() {
        udpPingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendUDPPing()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sendUDPPing() async {
        guard let transport else { return }
        var ping = MumbleUDP_Ping()
        ping.timestamp = UInt64(Date().timeIntervalSince1970)
        try? await transport.send(.ping(ping))

        if udpHealthy, Date().timeIntervalSince(lastPong) > Self.udpTimeout {
            // Voice falls back to the TCP tunnel; a desynced OCB2 state
            // is one cause, so ask the server for fresh nonces.
            udpHealthy = false
            await requestCryptResync?()
        }
    }

    private func notePong() {
        lastPong = Date()
        udpHealthy = true
    }

    // MARK: - Receive path

    private func shutdown() {
        receiveTask?.cancel()
        pumpTask?.cancel()
        captureTask?.cancel()
        udpPingTask?.cancel()
        receiveTask = nil
        pumpTask = nil
        captureTask = nil
        udpPingTask = nil
        input?.stop()
        input = nil
        transmitPipeline = nil
        transport?.close()
        transport = nil
        pipelines = [:]
        output.stop()
    }

    private func handle(_ audio: MumbleUDP_Audio) {
        let speaker = audio.senderSession
        guard !localMuted.contains(speaker), !deafened else { return }
        let pipeline: SpeakerPipeline
        if let existing = pipelines[speaker] {
            pipeline = existing
        } else {
            guard let fresh = try? SpeakerPipeline(sessionID: speaker) else { return }
            pipelines[speaker] = fresh
            pipeline = fresh
        }
        pipeline.receive(audio)
    }

    /// Tops up each speaker's playback ring to the target depth.
    private func pump() {
        var nowSpeaking: Set<UInt32> = []
        for (speaker, pipeline) in pipelines {
            var fed = false
            while output.bufferedSamples(for: speaker) < Self.targetBufferedSamples,
                let pcm = pipeline.nextPCM()
            {
                output.enqueue(pcm, for: speaker)
                fed = true
            }
            if fed || output.bufferedSamples(for: speaker) > 0 {
                nowSpeaking.insert(speaker)
            }
        }
        if nowSpeaking != speaking {
            speaking = nowSpeaking
            onSpeakingChanged?(nowSpeaking)
        }
    }
}
