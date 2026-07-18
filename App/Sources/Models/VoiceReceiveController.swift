import Foundation
import MumbleAudio
import MumbleConnection
import MumbleProtocol

/// Owns the UDP voice channel and the receive pipeline: incoming `Audio`
/// packets feed per-speaker jitter buffers, and a pump task keeps each
/// speaker's playback ring topped up with decoded PCM.
actor VoiceReceiveController {
    private var transport: MumbleUDPVoiceTransport?
    private var pipelines: [UInt32: SpeakerPipeline] = [:]
    private let output = VoiceAudioOutput()

    private var receiveTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var onSpeakingChanged: (@Sendable (Set<UInt32>) -> Void)?
    private var speaking: Set<UInt32> = []

    /// Playback ring target: 100ms ahead of the render head.
    private static let targetBufferedSamples = MumbleAudioConstants.sampleRate / 10

    func start(
        host: String,
        port: UInt16,
        cryptSetup: MumbleProto_CryptSetup,
        onSpeakingChanged: @escaping @Sendable (Set<UInt32>) -> Void
    ) async {
        self.onSpeakingChanged = onSpeakingChanged

        do {
            try output.start()
        } catch {
            // No audio device (e.g. CI) — voice is silently disabled.
            return
        }

        guard
            let transport = MumbleUDPVoiceTransport(
                host: host, port: port, cryptSetup: cryptSetup)
        else { return }
        self.transport = transport

        do {
            try await transport.open()
        } catch {
            self.transport = nil
            return
        }

        // Prime the server's crypt association for our source address.
        var ping = MumbleUDP_Ping()
        ping.timestamp = UInt64(Date().timeIntervalSince1970)
        try? await transport.send(.ping(ping))

        receiveTask = Task { [weak self] in
            for await packet in transport.incoming {
                guard let self else { return }
                if case .audio(let audio) = packet {
                    await self.handle(audio)
                }
            }
        }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pump()
                try? await Task.sleep(for: .milliseconds(10))
            }
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

    private func shutdown() {
        receiveTask?.cancel()
        pumpTask?.cancel()
        receiveTask = nil
        pumpTask = nil
        transport?.close()
        transport = nil
        pipelines = [:]
        output.stop()
    }

    private func handle(_ audio: MumbleUDP_Audio) {
        let speaker = audio.senderSession
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
