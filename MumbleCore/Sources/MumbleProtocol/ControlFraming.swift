import Foundation

/// Control-channel message types — the 16-bit wire prefix IDs from the
/// X-macro in upstream `MumbleProtocol.h`.
public enum MumbleMessageType: UInt16, CaseIterable, Sendable {
    case version = 0
    case udpTunnel = 1
    case authenticate = 2
    case ping = 3
    case reject = 4
    case serverSync = 5
    case channelRemove = 6
    case channelState = 7
    case userRemove = 8
    case userState = 9
    case banList = 10
    case textMessage = 11
    case permissionDenied = 12
    case acl = 13
    case queryUsers = 14
    case cryptSetup = 15
    case contextActionModify = 16
    case contextAction = 17
    case userList = 18
    case voiceTarget = 19
    case permissionQuery = 20
    case codecVersion = 21
    case userStats = 22
    case requestBlob = 23
    case serverConfig = 24
    case suggestConfig = 25
    case pluginDataTransmission = 26
}

/// One TCP control-channel frame: 2-byte big-endian type, 4-byte big-endian
/// payload length, payload. The payload is serialized protobuf for every
/// type except ``MumbleMessageType/udpTunnel``, which carries a raw voice
/// datagram and must never be protobuf-decoded.
public struct MumbleControlFrame: Equatable, Sendable {
    /// The raw 16-bit wire type. Kept alongside ``type`` so frames from
    /// newer protocol versions can be skipped instead of failing the stream.
    public var rawType: UInt16
    public var payload: Data

    /// The known message type, or nil for types this client doesn't know.
    public var type: MumbleMessageType? { MumbleMessageType(rawValue: rawType) }

    public init(type: MumbleMessageType, payload: Data) {
        self.rawType = type.rawValue
        self.payload = payload
    }

    public init(rawType: UInt16, payload: Data) {
        self.rawType = rawType
        self.payload = payload
    }

    public func encoded() -> Data {
        var out = Data(capacity: 6 + payload.count)
        out.append(UInt8(truncatingIfNeeded: rawType >> 8))
        out.append(UInt8(truncatingIfNeeded: rawType))
        let length = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

/// Incremental decoder for the TCP control stream. Feed it whatever byte
/// chunks arrive from the socket; it buffers partial frames internally and
/// yields complete frames as they become available.
public struct MumbleControlFrameDecoder: Sendable {
    /// Upstream rejects control messages larger than 8 MiB
    /// (`Connection::MAX_PAYLOAD_SIZE`); we enforce the same cap so a
    /// hostile or corrupt length prefix can't balloon the buffer.
    public static let defaultMaxPayloadSize = 8 * 1024 * 1024

    private var buffer = Data()
    private let maxPayloadSize: Int

    public init(maxPayloadSize: Int = MumbleControlFrameDecoder.defaultMaxPayloadSize) {
        self.maxPayloadSize = maxPayloadSize
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame, or nil if more bytes are needed.
    /// Call repeatedly after each ``append(_:)`` until it returns nil.
    public mutating func next() throws -> MumbleControlFrame? {
        guard buffer.count >= 6 else { return nil }

        let start = buffer.startIndex
        let rawType = UInt16(buffer[start]) << 8 | UInt16(buffer[start + 1])
        let length = Int(
            UInt32(buffer[start + 2]) << 24
                | UInt32(buffer[start + 3]) << 16
                | UInt32(buffer[start + 4]) << 8
                | UInt32(buffer[start + 5])
        )

        guard length <= maxPayloadSize else {
            throw MumbleWireError.payloadTooLarge(length: length, limit: maxPayloadSize)
        }
        guard buffer.count >= 6 + length else { return nil }

        let payload = Data(buffer[(start + 6)..<(start + 6 + length)])
        buffer.removeFirst(6 + length)
        return MumbleControlFrame(rawType: rawType, payload: payload)
    }
}
