import Foundation

/// Errors thrown while decoding Mumble wire data.
public enum MumbleWireError: Error, Equatable, Sendable {
    case truncated
    case malformedVarint
    case payloadTooLarge(length: Int, limit: Int)
}

/// The variable-length integer encoding used by Mumble's legacy UDP voice
/// packets, as defined by `PacketDataStream.h` in the upstream source.
///
/// Prefix scheme (first byte):
/// - `0xxxxxxx`            → 7-bit value
/// - `10xxxxxx` + 1 byte   → 14-bit value
/// - `110xxxxx` + 2 bytes  → 21-bit value
/// - `1110xxxx` + 3 bytes  → 28-bit value
/// - `111100..` + 4 bytes  → 32-bit value
/// - `111101..` + 8 bytes  → 64-bit value
/// - `111110..`            → bitwise complement of a recursively encoded varint
/// - `111111xx`            → bitwise complement of the low 2 bits
public enum MumbleVarint {
    /// Encodes a value using the raw 64-bit pattern, mirroring
    /// `PacketDataStream::operator<<(const quint64)`.
    public static func encode(_ value: UInt64) -> Data {
        var i = value
        var out = Data()

        if (i & 0x8000_0000_0000_0000) != 0 && (~i) < 0x1_0000_0000 {
            // Signed number, transmit the complement.
            i = ~i
            if i <= 0x3 {
                out.append(0xFC | UInt8(i))
                return out
            }
            out.append(0xF8)
        }

        if i < 0x80 {
            out.append(UInt8(i))
        } else if i < 0x4000 {
            out.append(0x80 | UInt8(i >> 8))
            out.append(UInt8(truncatingIfNeeded: i))
        } else if i < 0x20_0000 {
            out.append(0xC0 | UInt8(i >> 16))
            out.append(UInt8(truncatingIfNeeded: i >> 8))
            out.append(UInt8(truncatingIfNeeded: i))
        } else if i < 0x1000_0000 {
            out.append(0xE0 | UInt8(i >> 24))
            out.append(UInt8(truncatingIfNeeded: i >> 16))
            out.append(UInt8(truncatingIfNeeded: i >> 8))
            out.append(UInt8(truncatingIfNeeded: i))
        } else if i < 0x1_0000_0000 {
            out.append(0xF0)
            appendBigEndian(i, byteCount: 4, to: &out)
        } else {
            out.append(0xF4)
            appendBigEndian(i, byteCount: 8, to: &out)
        }
        return out
    }

    public static func encode(_ value: Int64) -> Data {
        encode(UInt64(bitPattern: value))
    }

    /// Decodes a varint starting at `offset`, advancing `offset` past it.
    public static func decode(_ data: Data, offset: inout Int) throws -> UInt64 {
        var complement = false
        var start = offset

        // The 0xF8 prefix wraps another varint whose decoded value must be
        // complemented. Upstream recurses; a second 0xF8 would just undo the
        // first, so more than one is malformed rather than meaningful.
        var prefix = try byte(data, at: start)
        if (prefix & 0xFC) == 0xF8 {
            complement = true
            start += 1
            prefix = try byte(data, at: start)
            if (prefix & 0xFC) == 0xF8 {
                throw MumbleWireError.malformedVarint
            }
        }

        var i: UInt64
        var consumed: Int

        if (prefix & 0x80) == 0x00 {
            i = UInt64(prefix & 0x7F)
            consumed = 1
        } else if (prefix & 0xC0) == 0x80 {
            i = UInt64(prefix & 0x3F) << 8 | UInt64(try byte(data, at: start + 1))
            consumed = 2
        } else if (prefix & 0xE0) == 0xC0 {
            i = UInt64(prefix & 0x1F) << 16
                | UInt64(try byte(data, at: start + 1)) << 8
                | UInt64(try byte(data, at: start + 2))
            consumed = 3
        } else if (prefix & 0xF0) == 0xE0 {
            i = UInt64(prefix & 0x0F) << 24
                | UInt64(try byte(data, at: start + 1)) << 16
                | UInt64(try byte(data, at: start + 2)) << 8
                | UInt64(try byte(data, at: start + 3))
            consumed = 4
        } else {
            switch prefix & 0xFC {
            case 0xF0:
                i = try readBigEndian(data, at: start + 1, byteCount: 4)
                consumed = 5
            case 0xF4:
                i = try readBigEndian(data, at: start + 1, byteCount: 8)
                consumed = 9
            case 0xFC:
                i = ~UInt64(prefix & 0x03)
                consumed = 1
            default:
                throw MumbleWireError.malformedVarint
            }
        }

        if complement {
            i = ~i
        }
        offset = start + consumed
        return i
    }

    private static func byte(_ data: Data, at index: Int) throws -> UInt8 {
        let absolute = data.startIndex + index
        guard absolute < data.endIndex else { throw MumbleWireError.truncated }
        return data[absolute]
    }

    private static func readBigEndian(_ data: Data, at index: Int, byteCount: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<byteCount {
            value = value << 8 | UInt64(try byte(data, at: index + i))
        }
        return value
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int, to data: inout Data) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
