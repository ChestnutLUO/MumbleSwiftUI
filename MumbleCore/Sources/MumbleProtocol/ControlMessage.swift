import Foundation
import SwiftProtobuf

/// A decoded control-channel message: one case per protobuf type in
/// `Mumble.proto`, plus the raw-bytes `udpTunnel` case.
public enum MumbleControlMessage: Sendable {
    case version(MumbleProto_Version)
    case udpTunnel(Data)
    case authenticate(MumbleProto_Authenticate)
    case ping(MumbleProto_Ping)
    case reject(MumbleProto_Reject)
    case serverSync(MumbleProto_ServerSync)
    case channelRemove(MumbleProto_ChannelRemove)
    case channelState(MumbleProto_ChannelState)
    case userRemove(MumbleProto_UserRemove)
    case userState(MumbleProto_UserState)
    case banList(MumbleProto_BanList)
    case textMessage(MumbleProto_TextMessage)
    case permissionDenied(MumbleProto_PermissionDenied)
    case acl(MumbleProto_ACL)
    case queryUsers(MumbleProto_QueryUsers)
    case cryptSetup(MumbleProto_CryptSetup)
    case contextActionModify(MumbleProto_ContextActionModify)
    case contextAction(MumbleProto_ContextAction)
    case userList(MumbleProto_UserList)
    case voiceTarget(MumbleProto_VoiceTarget)
    case permissionQuery(MumbleProto_PermissionQuery)
    case codecVersion(MumbleProto_CodecVersion)
    case userStats(MumbleProto_UserStats)
    case requestBlob(MumbleProto_RequestBlob)
    case serverConfig(MumbleProto_ServerConfig)
    case suggestConfig(MumbleProto_SuggestConfig)
    case pluginDataTransmission(MumbleProto_PluginDataTransmission)

    /// Decodes a frame into a typed message. Returns nil for frame types
    /// this client doesn't know (forward compatibility — callers should
    /// skip them). Throws if the payload fails protobuf decoding.
    public init?(frame: MumbleControlFrame) throws {
        guard let type = frame.type else { return nil }
        switch type {
        case .version: self = .version(try MumbleProto_Version(serializedBytes: frame.payload))
        case .udpTunnel: self = .udpTunnel(frame.payload)
        case .authenticate: self = .authenticate(try MumbleProto_Authenticate(serializedBytes: frame.payload))
        case .ping: self = .ping(try MumbleProto_Ping(serializedBytes: frame.payload))
        case .reject: self = .reject(try MumbleProto_Reject(serializedBytes: frame.payload))
        case .serverSync: self = .serverSync(try MumbleProto_ServerSync(serializedBytes: frame.payload))
        case .channelRemove: self = .channelRemove(try MumbleProto_ChannelRemove(serializedBytes: frame.payload))
        case .channelState: self = .channelState(try MumbleProto_ChannelState(serializedBytes: frame.payload))
        case .userRemove: self = .userRemove(try MumbleProto_UserRemove(serializedBytes: frame.payload))
        case .userState: self = .userState(try MumbleProto_UserState(serializedBytes: frame.payload))
        case .banList: self = .banList(try MumbleProto_BanList(serializedBytes: frame.payload))
        case .textMessage: self = .textMessage(try MumbleProto_TextMessage(serializedBytes: frame.payload))
        case .permissionDenied: self = .permissionDenied(try MumbleProto_PermissionDenied(serializedBytes: frame.payload))
        case .acl: self = .acl(try MumbleProto_ACL(serializedBytes: frame.payload))
        case .queryUsers: self = .queryUsers(try MumbleProto_QueryUsers(serializedBytes: frame.payload))
        case .cryptSetup: self = .cryptSetup(try MumbleProto_CryptSetup(serializedBytes: frame.payload))
        case .contextActionModify: self = .contextActionModify(try MumbleProto_ContextActionModify(serializedBytes: frame.payload))
        case .contextAction: self = .contextAction(try MumbleProto_ContextAction(serializedBytes: frame.payload))
        case .userList: self = .userList(try MumbleProto_UserList(serializedBytes: frame.payload))
        case .voiceTarget: self = .voiceTarget(try MumbleProto_VoiceTarget(serializedBytes: frame.payload))
        case .permissionQuery: self = .permissionQuery(try MumbleProto_PermissionQuery(serializedBytes: frame.payload))
        case .codecVersion: self = .codecVersion(try MumbleProto_CodecVersion(serializedBytes: frame.payload))
        case .userStats: self = .userStats(try MumbleProto_UserStats(serializedBytes: frame.payload))
        case .requestBlob: self = .requestBlob(try MumbleProto_RequestBlob(serializedBytes: frame.payload))
        case .serverConfig: self = .serverConfig(try MumbleProto_ServerConfig(serializedBytes: frame.payload))
        case .suggestConfig: self = .suggestConfig(try MumbleProto_SuggestConfig(serializedBytes: frame.payload))
        case .pluginDataTransmission: self = .pluginDataTransmission(try MumbleProto_PluginDataTransmission(serializedBytes: frame.payload))
        }
    }

    public var messageType: MumbleMessageType {
        switch self {
        case .version: .version
        case .udpTunnel: .udpTunnel
        case .authenticate: .authenticate
        case .ping: .ping
        case .reject: .reject
        case .serverSync: .serverSync
        case .channelRemove: .channelRemove
        case .channelState: .channelState
        case .userRemove: .userRemove
        case .userState: .userState
        case .banList: .banList
        case .textMessage: .textMessage
        case .permissionDenied: .permissionDenied
        case .acl: .acl
        case .queryUsers: .queryUsers
        case .cryptSetup: .cryptSetup
        case .contextActionModify: .contextActionModify
        case .contextAction: .contextAction
        case .userList: .userList
        case .voiceTarget: .voiceTarget
        case .permissionQuery: .permissionQuery
        case .codecVersion: .codecVersion
        case .userStats: .userStats
        case .requestBlob: .requestBlob
        case .serverConfig: .serverConfig
        case .suggestConfig: .suggestConfig
        case .pluginDataTransmission: .pluginDataTransmission
        }
    }

    /// Serializes into a wire-ready frame.
    public func frame() throws -> MumbleControlFrame {
        let payload: Data
        switch self {
        case .version(let m): payload = try m.serializedData()
        case .udpTunnel(let data): payload = data
        case .authenticate(let m): payload = try m.serializedData()
        case .ping(let m): payload = try m.serializedData()
        case .reject(let m): payload = try m.serializedData()
        case .serverSync(let m): payload = try m.serializedData()
        case .channelRemove(let m): payload = try m.serializedData()
        case .channelState(let m): payload = try m.serializedData()
        case .userRemove(let m): payload = try m.serializedData()
        case .userState(let m): payload = try m.serializedData()
        case .banList(let m): payload = try m.serializedData()
        case .textMessage(let m): payload = try m.serializedData()
        case .permissionDenied(let m): payload = try m.serializedData()
        case .acl(let m): payload = try m.serializedData()
        case .queryUsers(let m): payload = try m.serializedData()
        case .cryptSetup(let m): payload = try m.serializedData()
        case .contextActionModify(let m): payload = try m.serializedData()
        case .contextAction(let m): payload = try m.serializedData()
        case .userList(let m): payload = try m.serializedData()
        case .voiceTarget(let m): payload = try m.serializedData()
        case .permissionQuery(let m): payload = try m.serializedData()
        case .codecVersion(let m): payload = try m.serializedData()
        case .userStats(let m): payload = try m.serializedData()
        case .requestBlob(let m): payload = try m.serializedData()
        case .serverConfig(let m): payload = try m.serializedData()
        case .suggestConfig(let m): payload = try m.serializedData()
        case .pluginDataTransmission(let m): payload = try m.serializedData()
        }
        return MumbleControlFrame(type: messageType, payload: payload)
    }
}

/// Mumble version numbers, in both wire encodings. 1.5+ peers send both
/// `version_v1` and `version_v2` in their `Version` message; a peer sending
/// only v1 is pre-1.5 (and therefore speaks the legacy UDP voice format).
public struct MumbleVersion: Equatable, Comparable, Sendable {
    public var major: UInt16
    public var minor: UInt16
    public var patch: UInt16

    public init(major: UInt16, minor: UInt16, patch: UInt16) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Legacy format: `major << 16 | minor << 8 | patch`, components
    /// saturated to their field width.
    public var v1: UInt32 {
        UInt32(major) << 16 | UInt32(min(minor, 255)) << 8 | UInt32(min(patch, 255))
    }

    /// New format (Mumble ≥1.5): 16 bits per component, low 16 bits reserved.
    public var v2: UInt64 {
        UInt64(major) << 48 | UInt64(minor) << 32 | UInt64(patch) << 16
    }

    public init(v1: UInt32) {
        major = UInt16(truncatingIfNeeded: v1 >> 16)
        minor = UInt16((v1 >> 8) & 0xFF)
        patch = UInt16(v1 & 0xFF)
    }

    public init(v2: UInt64) {
        major = UInt16(truncatingIfNeeded: v2 >> 48)
        minor = UInt16(truncatingIfNeeded: v2 >> 32)
        patch = UInt16(truncatingIfNeeded: v2 >> 16)
    }

    /// First version that speaks the protobuf-based UDP voice protocol.
    public static let protobufUDPIntroduction = MumbleVersion(major: 1, minor: 5, patch: 0)

    public static func < (lhs: MumbleVersion, rhs: MumbleVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
