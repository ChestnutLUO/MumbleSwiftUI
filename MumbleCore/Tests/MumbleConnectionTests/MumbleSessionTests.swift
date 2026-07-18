import Foundation
import Testing
import MumbleProtocol
@testable import MumbleConnection

@Suite("MumbleSession handshake")
struct MumbleSessionTests {
    private func makeConfiguration() -> MumbleSessionConfiguration {
        MumbleSessionConfiguration(
            host: "test.invalid",
            username: "tester",
            connectTimeout: .seconds(5)
        )
    }

    /// Preloads a full server-side handshake script on the mock.
    private func scriptHandshake(on transport: MockTransport) async throws {
        var version = MumbleProto_Version()
        version.versionV1 = MumbleVersion(major: 1, minor: 5, patch: 901).v1
        version.versionV2 = MumbleVersion(major: 1, minor: 5, patch: 901).v2
        try await transport.serverSends(.version(version))

        var crypt = MumbleProto_CryptSetup()
        crypt.key = Data(repeating: 0xAB, count: 16)
        crypt.clientNonce = Data(repeating: 0x01, count: 16)
        crypt.serverNonce = Data(repeating: 0x02, count: 16)
        try await transport.serverSends(.cryptSetup(crypt))

        var codec = MumbleProto_CodecVersion()
        codec.alpha = -2_147_483_637
        codec.beta = 0
        codec.preferAlpha = true
        codec.opus = true
        try await transport.serverSends(.codecVersion(codec))

        var root = MumbleProto_ChannelState()
        root.channelID = 0
        root.name = "Root"
        try await transport.serverSends(.channelState(root))

        var lobby = MumbleProto_ChannelState()
        lobby.channelID = 3
        lobby.name = "Lobby"
        lobby.parent = 0
        try await transport.serverSends(.channelState(lobby))

        var ourUser = MumbleProto_UserState()
        ourUser.session = 42
        ourUser.name = "tester"
        ourUser.channelID = 0
        try await transport.serverSends(.userState(ourUser))

        var sync = MumbleProto_ServerSync()
        sync.session = 42
        sync.maxBandwidth = 558_000
        sync.welcomeText = "welcome"
        try await transport.serverSends(.serverSync(sync))
    }

    @Test("handshake completes on ServerSync with state populated")
    func successfulHandshake() async throws {
        let transport = MockTransport()
        try await scriptHandshake(on: transport)

        let session = MumbleSession(configuration: makeConfiguration(), transport: transport)
        let info = try await session.connect()

        #expect(info.sessionID == 42)
        #expect(info.maxBandwidth == 558_000)
        #expect(info.welcomeText == "welcome")

        let state = await session.state
        #expect(state.rootChannel?.name == "Root")
        #expect(state.channels[3]?.name == "Lobby")
        #expect(state.users[42]?.name == "tester")

        let serverVersion = await session.serverVersion
        #expect(serverVersion == MumbleVersion(major: 1, minor: 5, patch: 901))
        let crypt = await session.cryptSetup
        #expect(crypt?.key == Data(repeating: 0xAB, count: 16))

        // Client must have sent Version then Authenticate.
        let sent = await transport.sentMessages
        guard sent.count >= 2,
            case .version(let clientVersion) = sent[0],
            case .authenticate(let auth) = sent[1]
        else {
            Issue.record("expected Version then Authenticate, got \(sent.map(\.messageType))")
            return
        }
        #expect(clientVersion.hasVersionV2)
        #expect(auth.username == "tester")
        #expect(auth.opus)

        await session.disconnect()
        #expect(await transport.closed)
    }

    @Test("Reject fails the handshake with type and reason")
    func rejectedHandshake() async throws {
        let transport = MockTransport()
        var reject = MumbleProto_Reject()
        reject.type = .wrongUserPw
        reject.reason = "Wrong password"
        try await transport.serverSends(.reject(reject))

        let session = MumbleSession(configuration: makeConfiguration(), transport: transport)
        await #expect(throws: MumbleSessionError.self) {
            try await session.connect()
        }
    }

    @Test("transport closing mid-handshake fails connect")
    func closedDuringHandshake() async throws {
        let transport = MockTransport()
        await transport.serverCloses()

        let session = MumbleSession(configuration: makeConfiguration(), transport: transport)
        await #expect(throws: MumbleSessionError.self) {
            try await session.connect()
        }
    }

    @Test("handshake times out without ServerSync")
    func handshakeTimeout() async throws {
        let transport = MockTransport()
        var config = makeConfiguration()
        config.connectTimeout = .milliseconds(100)

        let session = MumbleSession(configuration: config, transport: transport)
        do {
            _ = try await session.connect()
            Issue.record("connect should have timed out")
        } catch let error as MumbleSessionError {
            #expect(error == .timeout)
        }
    }

    @Test("nonce-only CryptSetup updates nonces, keeps key")
    func cryptResyncUpdate() async throws {
        let transport = MockTransport()
        try await scriptHandshake(on: transport)

        let session = MumbleSession(configuration: makeConfiguration(), transport: transport)
        _ = try await session.connect()

        var resync = MumbleProto_CryptSetup()
        resync.serverNonce = Data(repeating: 0x99, count: 16)
        try await transport.serverSends(.cryptSetup(resync))

        // Give the receive loop a beat to process the injected frame.
        try await Task.sleep(for: .milliseconds(50))
        let crypt = await session.cryptSetup
        #expect(crypt?.key == Data(repeating: 0xAB, count: 16))
        #expect(crypt?.serverNonce == Data(repeating: 0x99, count: 16))
        #expect(crypt?.clientNonce == Data(repeating: 0x01, count: 16))

        await session.disconnect()
    }

    @Test("events stream reports text messages and state changes")
    func eventStream() async throws {
        let transport = MockTransport()
        try await scriptHandshake(on: transport)

        let session = MumbleSession(configuration: makeConfiguration(), transport: transport)
        _ = try await session.connect()

        var text = MumbleProto_TextMessage()
        text.message = "hi all"
        try await transport.serverSends(.textMessage(text))

        for await event in await session.events {
            if case .textMessage(let received) = event {
                #expect(received.message == "hi all")
                break
            }
        }
        await session.disconnect()
    }
}
