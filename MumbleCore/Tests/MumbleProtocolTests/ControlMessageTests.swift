import Foundation
import Testing
@testable import MumbleProtocol

@Suite("Typed control messages")
struct ControlMessageTests {
    @Test("Version round-trips through frame encoding")
    func versionRoundTrip() throws {
        var version = MumbleProto_Version()
        let ours = MumbleVersion(major: 1, minor: 5, patch: 0)
        version.versionV1 = ours.v1
        version.versionV2 = ours.v2
        version.release = "MumbleSwiftUI"
        version.os = "macOS"

        let wire = try MumbleControlMessage.version(version).frame().encoded()

        var decoder = MumbleControlFrameDecoder()
        decoder.append(wire)
        let frame = try #require(try decoder.next())
        let message = try #require(try MumbleControlMessage(frame: frame))

        guard case .version(let decoded) = message else {
            Issue.record("expected .version, got \(message)")
            return
        }
        #expect(decoded.versionV1 == 0x1_0500)
        #expect(decoded.versionV2 == 0x0001_0005_0000_0000)
        #expect(decoded.release == "MumbleSwiftUI")
    }

    @Test("Authenticate carries opus flag and tokens")
    func authenticateRoundTrip() throws {
        var auth = MumbleProto_Authenticate()
        auth.username = "digby"
        auth.opus = true
        auth.tokens = ["secret"]

        let frame = try MumbleControlMessage.authenticate(auth).frame()
        #expect(frame.type == .authenticate)

        let message = try #require(try MumbleControlMessage(frame: frame))
        guard case .authenticate(let decoded) = message else {
            Issue.record("expected .authenticate, got \(message)")
            return
        }
        #expect(decoded.username == "digby")
        #expect(decoded.opus)
        #expect(decoded.tokens == ["secret"])
    }

    @Test("UDPTunnel payload passes through untouched")
    func udpTunnelPassthrough() throws {
        // Deliberately not valid protobuf — tunnel payloads are raw voice datagrams.
        let datagram = Data([0x80, 0x01, 0x02, 0xFF])
        let frame = try MumbleControlMessage.udpTunnel(datagram).frame()
        let message = try #require(try MumbleControlMessage(frame: frame))
        guard case .udpTunnel(let payload) = message else {
            Issue.record("expected .udpTunnel, got \(message)")
            return
        }
        #expect(payload == datagram)
    }

    @Test("unknown frame type decodes to nil")
    func unknownFrame() throws {
        let frame = MumbleControlFrame(rawType: 4242, payload: Data())
        #expect(try MumbleControlMessage(frame: frame) == nil)
    }

    @Test("version v1/v2 encodings agree with upstream Version.h")
    func versionEncodings() {
        let v = MumbleVersion(major: 1, minor: 5, patch: 901)
        #expect(v.v2 == 0x0001_0005_0385_0000)
        // v1 saturates patch at 255
        #expect(v.v1 == 0x0001_05FF)
        #expect(MumbleVersion(v2: v.v2) == v)
        #expect(MumbleVersion(v1: 0x1_0204) == MumbleVersion(major: 1, minor: 2, patch: 4))
        #expect(MumbleVersion(major: 1, minor: 4, patch: 287) < MumbleVersion.protobufUDPIntroduction)
        #expect(!(MumbleVersion(major: 1, minor: 5, patch: 0) < .protobufUDPIntroduction))
    }
}
