import Foundation
import Testing
@testable import MumbleProtocol

@Suite("Mumble varint codec")
struct VarintTests {
    private func roundTrip(_ value: UInt64) throws -> UInt64 {
        let encoded = MumbleVarint.encode(value)
        var offset = 0
        let decoded = try MumbleVarint.decode(encoded, offset: &offset)
        #expect(offset == encoded.count, "decoder must consume exactly what the encoder produced")
        return decoded
    }

    @Test("known byte encodings match PacketDataStream")
    func knownEncodings() {
        // 7-bit
        #expect(MumbleVarint.encode(UInt64(0)) == Data([0x00]))
        #expect(MumbleVarint.encode(UInt64(0x7F)) == Data([0x7F]))
        // 14-bit: 0x80 = 10000000 10000000
        #expect(MumbleVarint.encode(UInt64(0x80)) == Data([0x80, 0x80]))
        #expect(MumbleVarint.encode(UInt64(0x3FFF)) == Data([0xBF, 0xFF]))
        // 21-bit
        #expect(MumbleVarint.encode(UInt64(0x4000)) == Data([0xC0, 0x40, 0x00]))
        #expect(MumbleVarint.encode(UInt64(0x1F_FFFF)) == Data([0xDF, 0xFF, 0xFF]))
        // 28-bit
        #expect(MumbleVarint.encode(UInt64(0x20_0000)) == Data([0xE0, 0x20, 0x00, 0x00]))
        #expect(MumbleVarint.encode(UInt64(0x0FFF_FFFF)) == Data([0xEF, 0xFF, 0xFF, 0xFF]))
        // 32-bit
        #expect(MumbleVarint.encode(UInt64(0x1000_0000)) == Data([0xF0, 0x10, 0x00, 0x00, 0x00]))
        #expect(MumbleVarint.encode(UInt64(0xFFFF_FFFF)) == Data([0xF0, 0xFF, 0xFF, 0xFF, 0xFF]))
        // 64-bit
        #expect(
            MumbleVarint.encode(UInt64(0x1_0000_0000))
                == Data([0xF4, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]))
    }

    @Test("small negative numbers use the 111111xx form")
    func smallNegatives() throws {
        // The low 2 bits hold the complement: ~(-1) = 0, ~(-4) = 3.
        #expect(MumbleVarint.encode(Int64(-1)) == Data([0xFC]))
        #expect(MumbleVarint.encode(Int64(-4)) == Data([0xFF]))
        for v in Int64(-4)...(-1) {
            let encoded = MumbleVarint.encode(v)
            #expect(encoded.count == 1)
            var offset = 0
            let decoded = try MumbleVarint.decode(encoded, offset: &offset)
            #expect(Int64(bitPattern: decoded) == v)
        }
    }

    @Test("larger negative numbers use the 111110 complement prefix")
    func complementNegatives() throws {
        let value = Int64(-1000)
        let encoded = MumbleVarint.encode(value)
        #expect(encoded.first == 0xF8)
        var offset = 0
        let decoded = try MumbleVarint.decode(encoded, offset: &offset)
        #expect(Int64(bitPattern: decoded) == value)
        #expect(offset == encoded.count)
    }

    @Test("round trip across all width boundaries")
    func roundTripBoundaries() throws {
        let values: [UInt64] = [
            0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 0x1F_FFFF, 0x20_0000,
            0x0FFF_FFFF, 0x1000_0000, 0xFFFF_FFFF, 0x1_0000_0000,
            0xFFFF_FFFF_FFFF, UInt64.max,
        ]
        for v in values {
            #expect(try roundTrip(v) == v)
        }
    }

    @Test("round trip signed values")
    func roundTripSigned() throws {
        for v: Int64 in [-1, -4, -5, -128, -65_536, -2_147_483_648, Int64.min] {
            let decoded = try roundTrip(UInt64(bitPattern: v))
            #expect(Int64(bitPattern: decoded) == v)
        }
    }

    @Test("decode consumes from a mid-buffer offset")
    func decodeAtOffset() throws {
        var data = Data([0xAA, 0xBB])
        data.append(MumbleVarint.encode(UInt64(300)))
        data.append(MumbleVarint.encode(UInt64(7)))
        var offset = 2
        #expect(try MumbleVarint.decode(data, offset: &offset) == 300)
        #expect(try MumbleVarint.decode(data, offset: &offset) == 7)
        #expect(offset == data.count)
    }

    @Test("truncated input throws")
    func truncated() {
        var offset = 0
        #expect(throws: MumbleWireError.truncated) {
            var o = 0
            _ = try MumbleVarint.decode(Data(), offset: &o)
        }
        #expect(throws: MumbleWireError.truncated) {
            _ = try MumbleVarint.decode(Data([0xF4, 0x00, 0x00]), offset: &offset)
        }
    }

    @Test("nested complement prefix is rejected")
    func nestedComplement() {
        var offset = 0
        #expect(throws: MumbleWireError.malformedVarint) {
            _ = try MumbleVarint.decode(Data([0xF8, 0xF8, 0x01]), offset: &offset)
        }
    }

    @Test("decode works on a Data slice with nonzero startIndex")
    func sliceSafety() throws {
        let full = Data([0xFF, 0xFF]) + MumbleVarint.encode(UInt64(12345))
        let slice = full.dropFirst(2)
        var offset = 0
        #expect(try MumbleVarint.decode(slice, offset: &offset) == 12345)
    }
}
