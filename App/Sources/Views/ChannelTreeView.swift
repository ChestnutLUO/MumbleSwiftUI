import MumbleConnection
import SwiftUI

struct ChannelTreeView: View {
    @Environment(SessionController.self) private var controller
    @State private var newChannelParent: MumbleChannel?
    @State private var newChannelName = ""

    var body: some View {
        List {
            if let root = controller.serverState.rootChannel {
                ChannelSection(channel: root, onCreateChannel: { parent in
                    newChannelParent = parent
                    newChannelName = ""
                })
            }
        }
        .listStyle(.sidebar)
        .alert(
            "New Channel",
            isPresented: Binding(
                get: { newChannelParent != nil },
                set: { if !$0 { newChannelParent = nil } }
            ),
            presenting: newChannelParent
        ) { parent in
            TextField("Channel name", text: $newChannelName)
            Button("Create") {
                controller.createChannel(name: newChannelName, parentID: parent.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { parent in
            Text("Create a channel under “\(parent.name.isEmpty ? "Root" : parent.name)”.")
        }
    }
}

private struct ChannelSection: View {
    @Environment(SessionController.self) private var controller
    let channel: MumbleChannel
    let onCreateChannel: (MumbleChannel) -> Void

    var body: some View {
        channelRow
        // Users in this channel.
        ForEach(controller.serverState.users(inChannel: channel.id)) { user in
            UserRow(user: user)
                .padding(.leading, 16)
        }
        // Child channels, indented via recursion.
        ForEach(controller.serverState.childChannels(of: channel.id)) { child in
            ChannelSection(channel: child, onCreateChannel: onCreateChannel)
                .padding(.leading, 12)
        }
    }

    private var channelRow: some View {
        Button {
            controller.joinChannel(channel.id)
        } label: {
            Label {
                Text(channel.name.isEmpty ? "Root" : channel.name)
                    .fontWeight(isOwnChannel ? .semibold : .regular)
            } icon: {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Join \(channel.name)")
        .contextMenu {
            Button("Join Channel") {
                controller.joinChannel(channel.id)
            }
            Button("Create Channel Here…") {
                onCreateChannel(channel)
            }
        }
    }

    private var isOwnChannel: Bool {
        controller.ownUser?.channelID == channel.id
    }
}

private struct UserRow: View {
    @Environment(SessionController.self) private var controller
    let user: MumbleUser

    private var isSpeaking: Bool {
        controller.speakingSessions.contains(user.id)
    }

    private var isSelf: Bool {
        user.id == controller.ownUser?.id
    }

    private var isLocallyMuted: Bool {
        controller.locallyMuted.contains(user.id)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSpeaking ? "waveform" : "person.fill")
                .foregroundStyle(isSpeaking ? .green : .secondary)
                .frame(width: 16)
            Text(user.name)
            Spacer()
            if isLocallyMuted {
                Image(systemName: "speaker.slash.circle")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                    .help("Muted locally")
            }
            if user.isSelfMuted || user.isMuted {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.red.opacity(0.8))
                    .imageScale(.small)
            }
            if user.isSelfDeafened || user.isDeafened {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(.red.opacity(0.8))
                    .imageScale(.small)
            }
        }
        .foregroundStyle(isSelf ? .primary : .secondary)
        .contextMenu {
            if !isSelf {
                Button("Send Private Message") {
                    controller.startPrivateChat(with: user)
                }
                Button(isLocallyMuted ? "Unmute Locally" : "Mute Locally") {
                    controller.setLocalMute(user.id, muted: !isLocallyMuted)
                }
            }
        }
    }
}
