import Foundation
import MumbleProtocol

/// A channel on the server, kept in sync from `ChannelState` deltas.
public struct MumbleChannel: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public var name: String = ""
    /// nil for the root channel (id 0) only.
    public var parentID: UInt32?
    public var channelDescription: String = ""
    public var position: Int32 = 0
    public var isTemporary: Bool = false
    public var maxUsers: UInt32 = 0
    public var linkedChannelIDs: Set<UInt32> = []

    public init(id: UInt32) {
        self.id = id
    }
}

/// A connected user, kept in sync from `UserState` deltas.
public struct MumbleUser: Identifiable, Equatable, Sendable {
    /// The server-assigned session id — the key voice packets refer to.
    public let id: UInt32
    public var name: String = ""
    public var channelID: UInt32 = 0
    /// Registration id; nil for unregistered users.
    public var registeredUserID: UInt32?
    public var isMuted: Bool = false
    public var isDeafened: Bool = false
    public var isSuppressed: Bool = false
    public var isSelfMuted: Bool = false
    public var isSelfDeafened: Bool = false
    public var isPrioritySpeaker: Bool = false
    public var isRecording: Bool = false
    public var comment: String = ""
    public var certificateHash: String = ""

    public init(id: UInt32) {
        self.id = id
    }
}

/// Mutable mirror of the server's channel/user tree.
///
/// `ChannelState` and `UserState` are deltas: in proto2, only fields the
/// server actually set are merged; everything else keeps its current value.
public struct MumbleServerState: Equatable, Sendable {
    public private(set) var channels: [UInt32: MumbleChannel] = [:]
    public private(set) var users: [UInt32: MumbleUser] = [:]

    public init() {}

    public var rootChannel: MumbleChannel? { channels[0] }

    public func users(inChannel channelID: UInt32) -> [MumbleUser] {
        users.values.filter { $0.channelID == channelID }.sorted { $0.name < $1.name }
    }

    public func childChannels(of channelID: UInt32) -> [MumbleChannel] {
        channels.values
            .filter { $0.parentID == channelID && $0.id != channelID }
            .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    public mutating func apply(_ message: MumbleProto_ChannelState) {
        guard message.hasChannelID else { return }
        var channel = channels[message.channelID] ?? MumbleChannel(id: message.channelID)
        if message.hasName { channel.name = message.name }
        if message.hasParent { channel.parentID = message.parent }
        if message.hasDescription_p { channel.channelDescription = message.description_p }
        if message.hasPosition { channel.position = message.position }
        if message.hasTemporary { channel.isTemporary = message.temporary }
        if message.hasMaxUsers { channel.maxUsers = message.maxUsers }
        if !message.links.isEmpty { channel.linkedChannelIDs = Set(message.links) }
        channel.linkedChannelIDs.formUnion(message.linksAdd)
        channel.linkedChannelIDs.subtract(message.linksRemove)
        channels[message.channelID] = channel
    }

    public mutating func apply(_ message: MumbleProto_ChannelRemove) {
        guard message.hasChannelID else { return }
        channels.removeValue(forKey: message.channelID)
        // The server also removes descendants; mirror that so stale
        // subtrees can't linger if it doesn't send explicit removes.
        var removed = true
        while removed {
            removed = false
            for channel in channels.values {
                if let parent = channel.parentID, channels[parent] == nil, channel.id != 0 {
                    channels.removeValue(forKey: channel.id)
                    removed = true
                }
            }
        }
    }

    public mutating func apply(_ message: MumbleProto_UserState) {
        guard message.hasSession else { return }
        var user = users[message.session] ?? MumbleUser(id: message.session)
        if message.hasName { user.name = message.name }
        if message.hasChannelID { user.channelID = message.channelID }
        if message.hasUserID { user.registeredUserID = message.userID }
        if message.hasMute { user.isMuted = message.mute }
        if message.hasDeaf { user.isDeafened = message.deaf }
        if message.hasSuppress { user.isSuppressed = message.suppress }
        if message.hasSelfMute { user.isSelfMuted = message.selfMute }
        if message.hasSelfDeaf { user.isSelfDeafened = message.selfDeaf }
        if message.hasPrioritySpeaker { user.isPrioritySpeaker = message.prioritySpeaker }
        if message.hasRecording { user.isRecording = message.recording }
        if message.hasComment { user.comment = message.comment }
        if message.hasHash { user.certificateHash = message.hash }
        users[message.session] = user
    }

    public mutating func apply(_ message: MumbleProto_UserRemove) {
        guard message.hasSession else { return }
        users.removeValue(forKey: message.session)
    }
}
