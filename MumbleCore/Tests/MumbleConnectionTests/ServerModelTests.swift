import Foundation
import Testing
import MumbleProtocol
@testable import MumbleConnection

@Suite("Server state model")
struct ServerModelTests {
    private func channelState(
        id: UInt32, name: String? = nil, parent: UInt32? = nil
    ) -> MumbleProto_ChannelState {
        var message = MumbleProto_ChannelState()
        message.channelID = id
        if let name { message.name = name }
        if let parent { message.parent = parent }
        return message
    }

    private func userState(
        session: UInt32, name: String? = nil, channel: UInt32? = nil
    ) -> MumbleProto_UserState {
        var message = MumbleProto_UserState()
        message.session = session
        if let name { message.name = name }
        if let channel { message.channelID = channel }
        return message
    }

    @Test("channel deltas merge, absent fields keep prior values")
    func channelDeltaMerge() {
        var state = MumbleServerState()
        state.apply(channelState(id: 0, name: "Root"))
        state.apply(channelState(id: 5, name: "Lobby", parent: 0))

        // Delta with only a position change must not clear the name.
        var delta = MumbleProto_ChannelState()
        delta.channelID = 5
        delta.position = 3
        state.apply(delta)

        #expect(state.channels[5]?.name == "Lobby")
        #expect(state.channels[5]?.position == 3)
        #expect(state.channels[5]?.parentID == 0)
        #expect(state.rootChannel?.name == "Root")
        #expect(state.childChannels(of: 0).map(\.id) == [5])
    }

    @Test("channel links merge via links, links_add, links_remove")
    func channelLinks() {
        var state = MumbleServerState()
        var message = channelState(id: 2, name: "A", parent: 0)
        message.links = [3, 4]
        state.apply(message)
        #expect(state.channels[2]?.linkedChannelIDs == [3, 4])

        var delta = MumbleProto_ChannelState()
        delta.channelID = 2
        delta.linksAdd = [5]
        delta.linksRemove = [3]
        state.apply(delta)
        #expect(state.channels[2]?.linkedChannelIDs == [4, 5])
    }

    @Test("removing a channel prunes orphaned descendants")
    func channelRemoveCascades() {
        var state = MumbleServerState()
        state.apply(channelState(id: 0, name: "Root"))
        state.apply(channelState(id: 1, name: "Parent", parent: 0))
        state.apply(channelState(id: 2, name: "Child", parent: 1))
        state.apply(channelState(id: 3, name: "Grandchild", parent: 2))

        var remove = MumbleProto_ChannelRemove()
        remove.channelID = 1
        state.apply(remove)

        #expect(state.channels.keys.sorted() == [0])
    }

    @Test("user deltas merge, absent fields keep prior values")
    func userDeltaMerge() {
        var state = MumbleServerState()
        state.apply(userState(session: 7, name: "alice", channel: 0))

        var delta = MumbleProto_UserState()
        delta.session = 7
        delta.selfMute = true
        state.apply(delta)

        #expect(state.users[7]?.name == "alice")
        #expect(state.users[7]?.isSelfMuted == true)
        #expect(state.users[7]?.channelID == 0)

        state.apply(userState(session: 7, channel: 4))
        #expect(state.users[7]?.channelID == 4)
        #expect(state.users[7]?.isSelfMuted == true)
    }

    @Test("user remove and per-channel listing")
    func userRemoveAndListing() {
        var state = MumbleServerState()
        state.apply(userState(session: 1, name: "bob", channel: 0))
        state.apply(userState(session: 2, name: "alice", channel: 0))
        state.apply(userState(session: 3, name: "carol", channel: 9))

        #expect(state.users(inChannel: 0).map(\.name) == ["alice", "bob"])

        var remove = MumbleProto_UserRemove()
        remove.session = 2
        state.apply(remove)
        #expect(state.users(inChannel: 0).map(\.name) == ["bob"])
        #expect(state.users.count == 2)
    }
}
