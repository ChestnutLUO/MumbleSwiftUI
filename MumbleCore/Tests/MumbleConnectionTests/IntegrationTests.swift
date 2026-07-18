import Foundation
import Testing
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
}
