import Foundation
import Testing
import MumbleAudio
import MumbleProtocol
@testable import MumbleConnection

/// Runs against a real local server (OrbStack container `mumble-test`).
/// Enable with: MUMBLE_INTEGRATION=1 swift test
@Suite(
    "Live server integration",
    .enabled(if: ProcessInfo.processInfo.environment["MUMBLE_INTEGRATION"] == "1")
)
struct IntegrationTests {
    @Test("connect, sync, join channel, text message, disconnect")
    func fullHandshake() async throws {
        let configuration = MumbleSessionConfiguration(
            host: "127.0.0.1",
            username: "integration-test-\(UInt32.random(in: 0..<100_000))",
            trustPolicy: .insecureAcceptAny,
            connectTimeout: .seconds(15)
        )
        let session = MumbleSession(configuration: configuration)
        let info = try await session.connect()

        #expect(info.sessionID != 0)
        #expect(info.maxBandwidth > 0)

        let state = await session.state
        #expect(state.rootChannel != nil)
        #expect(state.users[info.sessionID]?.name == configuration.username)

        let serverVersion = try #require(await session.serverVersion)
        #expect(serverVersion >= MumbleVersion.protobufUDPIntroduction)

        // Crypt material for the voice channel must have been delivered.
        let crypt = try #require(await session.cryptSetup)
        #expect(crypt.key.count == 16)

        try await session.sendTextMessage("hello from MumbleSwiftUI phase 2", toChannel: 0)

        await session.disconnect()
    }

    @Test("TOFU: certificate hash observed, pinning it succeeds, wrong pin fails")
    func certificatePinning() async throws {
        let first = TLSControlChannel(
            host: "127.0.0.1", port: 64738, trustPolicy: .insecureAcceptAny)
        try await first.open()
        let observedHash = try #require(first.serverCertificateSHA256)
        await first.close()

        let pinned = TLSControlChannel(
            host: "127.0.0.1", port: 64738,
            trustPolicy: .pinnedCertificateSHA256(observedHash))
        try await pinned.open()
        #expect(pinned.serverCertificateSHA256 == observedHash)
        await pinned.close()

        let wrongPin = TLSControlChannel(
            host: "127.0.0.1", port: 64738,
            trustPolicy: .pinnedCertificateSHA256(Data(repeating: 0, count: 32)))
        await #expect(throws: (any Error).self) {
            try await wrongPin.open()
        }
        await wrongPin.close()
    }

    @Test("UDP voice channel: encrypted ping round-trips with the server")
    func udpCryptPing() async throws {
        let configuration = MumbleSessionConfiguration(
            host: "127.0.0.1",
            username: "udp-ping-test-\(UInt32.random(in: 0..<100_000))",
            trustPolicy: .insecureAcceptAny,
            connectTimeout: .seconds(15)
        )
        let session = MumbleSession(configuration: configuration)
        _ = try await session.connect()

        let cryptSetup = try #require(await session.cryptSetup)
        let transport = try #require(
            MumbleUDPVoiceTransport(host: "127.0.0.1", port: 64738, cryptSetup: cryptSetup))
        try await transport.open()

        var ping = MumbleUDP_Ping()
        ping.timestamp = 0xDEC0DE
        try await transport.send(.ping(ping))

        // Await the echoed ping; fail rather than hang if it never comes.
        let reply = await withTaskGroup(of: MumbleVoicePacket?.self) { group in
            group.addTask {
                for await packet in transport.incoming {
                    return packet
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard case .ping(let pong)? = reply else {
            Issue.record("no UDP ping reply — OCB2 interop with murmur failed")
            transport.close()
            await session.disconnect()
            return
        }
        #expect(pong.timestamp == 0xDEC0DE)
        #expect(transport.statistics.good >= 1)

        transport.close()
        await session.disconnect()
    }

    @Test("E2E voice loopback: sine → Opus → encrypt → server → decrypt → decode")
    func voiceLoopback() async throws {
        let configuration = MumbleSessionConfiguration(
            host: "127.0.0.1",
            username: "loopback-test-\(UInt32.random(in: 0..<100_000))",
            trustPolicy: .insecureAcceptAny,
            connectTimeout: .seconds(15)
        )
        let session = MumbleSession(configuration: configuration)
        let info = try await session.connect()

        let cryptSetup = try #require(await session.cryptSetup)
        let transport = try #require(
            MumbleUDPVoiceTransport(host: "127.0.0.1", port: 64738, cryptSetup: cryptSetup))
        try await transport.open()
        defer { transport.close() }

        // Prime the server's crypt state for our address with a ping.
        var ping = MumbleUDP_Ping()
        ping.timestamp = 1
        try await transport.send(.ping(ping))

        let frameCount = 20
        let samplesPerFrame = 960  // 20 ms

        // Collector must be listening before we send.
        let received = Task { () -> [MumbleUDP_Audio] in
            var audio: [MumbleUDP_Audio] = []
            for await packet in transport.incoming {
                if case .audio(let frame) = packet {
                    audio.append(frame)
                    if audio.count == frameCount { break }
                }
            }
            return audio
        }

        let encoder = try OpusVoiceEncoder()
        for n in 0..<frameCount {
            let pcm = (0..<samplesPerFrame).map { i in
                0.5 * sin(2 * .pi * 440 * Float(n * samplesPerFrame + i) / 48_000)
            }
            var audio = MumbleUDP_Audio()
            audio.target = 31  // server loopback
            audio.frameNumber = UInt64(n)
            audio.opusData = try encoder.encode(pcm)
            audio.isTerminator = n == frameCount - 1
            try await transport.send(.audio(audio))
            // Pace like a real client so the server doesn't drop us.
            try await Task.sleep(for: .milliseconds(20))
        }

        let echoed = await withTaskGroup(of: [MumbleUDP_Audio]?.self) { group in
            group.addTask { await received.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            received.cancel()
            return first
        }

        let frames = try #require(echoed, "no loopback audio received within 10s")
        #expect(frames.count == frameCount)
        // Loopback packets echo back marked with our own session.
        #expect(frames.allSatisfy { $0.senderSession == info.sessionID })

        // Feed the receive pipeline exactly as live audio would arrive.
        let pipeline = try SpeakerPipeline(sessionID: info.sessionID)
        for frame in frames {
            pipeline.receive(frame)
        }
        var pcm: [Float] = []
        while let chunk = pipeline.nextPCM() {
            pcm.append(contentsOf: chunk)
        }
        #expect(pcm.count >= samplesPerFrame * (frameCount - 2), "most audio must survive")
        let energy = pcm.reduce(0) { $0 + $1 * $1 } / Float(max(pcm.count, 1))
        #expect(energy > 0.01, "decoded loopback audio must not be silence")

        await session.disconnect()
    }
}
