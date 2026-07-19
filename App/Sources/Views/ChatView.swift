import SwiftUI

struct ChatView: View {
    @Environment(SessionController.self) private var controller
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.chat) { message in
                            MessageRow(message: message)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: controller.chat.count) {
                    if let last = controller.chat.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            if case .user(_, let name) = controller.chatTarget {
                HStack(spacing: 6) {
                    Label("Private message to \(name)", systemImage: "envelope")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Spacer()
                    Button("Back to channel") {
                        controller.chatTarget = .currentChannel
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draft, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .onSubmit(send)
                Button("Send", systemImage: "paperplane.fill", action: send)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(draft.isEmpty)
            }
            .padding(10)
        }
        .navigationTitle(channelName)
    }

    private var channelName: String {
        guard let user = controller.ownUser,
            let channel = controller.serverState.channels[user.channelID]
        else { return "Chat" }
        return channel.name.isEmpty ? "Root" : channel.name
    }

    private var prompt: String {
        switch controller.chatTarget {
        case .currentChannel: "Message \(channelName)"
        case .user(_, let name): "Message \(name) privately"
        }
    }

    private func send() {
        controller.sendChat(draft)
        draft = ""
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.senderName)
                    .font(.caption.bold())
                if message.privateWith != nil {
                    Text("private")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(.purple.opacity(0.2), in: Capsule())
                        .foregroundStyle(.purple)
                }
                Text(message.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(plainText(fromHTML: message.text))
                .textSelection(.enabled)
        }
        .id(message.id)
    }
}
