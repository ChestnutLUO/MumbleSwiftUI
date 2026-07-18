import MumbleConnection
import SwiftUI

struct ChannelTreeView: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        List {
            if let root = controller.serverState.rootChannel {
                ChannelSection(channel: root)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ChannelSection: View {
    @Environment(SessionController.self) private var controller
    let channel: MumbleChannel

    var body: some View {
        channelRow
        // Users in this channel.
        ForEach(controller.serverState.users(inChannel: channel.id)) { user in
            UserRow(user: user)
                .padding(.leading, 16)
        }
        // Child channels, indented via recursion.
        ForEach(controller.serverState.childChannels(of: channel.id)) { child in
            ChannelSection(channel: child)
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSpeaking ? "waveform" : "person.fill")
                .foregroundStyle(isSpeaking ? .green : .secondary)
                .frame(width: 16)
            Text(user.name)
            Spacer()
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
        .foregroundStyle(user.id == controller.ownUser?.id ? .primary : .secondary)
    }
}
