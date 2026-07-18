import Foundation
import Testing
@testable import MumbleProtocol

@Suite("TCP control framing")
struct ControlFramingTests {
    @Test("frame encodes as 2-byte type + 4-byte length + payload, big-endian")
    func encoding() {
        let frame = MumbleControlFrame(type: .authenticate, payload: Data([0xDE, 0xAD]))
        #expect(frame.encoded() == Data([0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0xDE, 0xAD]))

        let empty = MumbleControlFrame(type: .ping, payload: Data())
        #expect(empty.encoded() == Data([0x00, 0x03, 0x00, 0x00, 0x00, 0x00]))
    }

    @Test("decoder yields a complete frame")
    func decodeWhole() throws {
        var decoder = MumbleControlFrameDecoder()
        decoder.append(MumbleControlFrame(type: .version, payload: Data([1, 2, 3])).encoded())
        let frame = try decoder.next()
        #expect(frame?.type == .version)
        #expect(frame?.payload == Data([1, 2, 3]))
        #expect(try decoder.next() == nil)
    }

    @Test("decoder reassembles frames fed one byte at a time")
    func decodeBytewise() throws {
        let wire = MumbleControlFrame(type: .textMessage, payload: Data("hello".utf8)).encoded()
        var decoder = MumbleControlFrameDecoder()
        for (i, byte) in wire.enumerated() {
            decoder.append(Data([byte]))
            let frame = try decoder.next()
            if i < wire.count - 1 {
                #expect(frame == nil)
            } else {
                #expect(frame?.type == .textMessage)
                #expect(frame?.payload == Data("hello".utf8))
            }
        }
    }

    @Test("decoder splits multiple frames from one chunk")
    func decodeCoalesced() throws {
        let a = MumbleControlFrame(type: .ping, payload: Data())
        let b = MumbleControlFrame(type: .udpTunnel, payload: Data([9, 9, 9]))
        var decoder = MumbleControlFrameDecoder()
        decoder.append(a.encoded() + b.encoded())
        #expect(try decoder.next() == a)
        #expect(try decoder.next() == b)
        #expect(try decoder.next() == nil)
    }

    @Test("unknown message types are surfaced, not fatal")
    func unknownType() throws {
        var decoder = MumbleControlFrameDecoder()
        decoder.append(MumbleControlFrame(rawType: 999, payload: Data([1])).encoded())
        decoder.append(MumbleControlFrame(type: .ping, payload: Data()).encoded())

        let unknown = try decoder.next()
        #expect(unknown?.type == nil)
        #expect(unknown?.rawType == 999)
        // The stream keeps working after skipping it.
        #expect(try decoder.next()?.type == .ping)
    }

    @Test("oversized length prefix throws instead of buffering")
    func oversized() {
        var decoder = MumbleControlFrameDecoder(maxPayloadSize: 16)
        var header = Data([0x00, 0x03])
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x11]) // length 17 > 16
        decoder.append(header)
        #expect(throws: MumbleWireError.payloadTooLarge(length: 17, limit: 16)) {
            _ = try decoder.next()
        }
    }
}
