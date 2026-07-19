import MumbleConnection
import SwiftUI

/// Adaptive session UI: split view with a full toolbar on macOS and
/// regular-width iPad; tabs plus a bottom voice bar on iPhone and
/// compact iPad windows.
struct SessionView: View {
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
            if sizeClass == .compact {
                CompactSessionView()
            } else {
                RegularSessionView()
            }
        #else
            RegularSessionView()
        #endif
    }
}

// MARK: - Regular width (macOS, iPad)

private struct RegularSessionView: View {
    @Environment(SessionController.self) private var controller
    @AppStorage(AudioPreferences.modeKey) private var transmitMode = TransmitMode.voiceActivity.rawValue
    @State private var showAudioSettings = false

    var body: some View {
        NavigationSplitView {
            ChannelTreeView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            ChatView()
        }
        .toolbar {
            #if os(macOS)
                ToolbarItem(placement: .status) {
                    if let info = controller.syncInfo, !info.welcomeText.isEmpty {
                        Text(plainText(fromHTML: info.welcomeText))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                if transmitMode == TransmitMode.pushToTalk.rawValue {
                    PushToTalkButton(style: .toolbar)
                }
                MuteButton()
                DeafenButton()
                Button("Audio Settings", systemImage: "gearshape") {
                    showAudioSettings = true
                }
                DisconnectButton()
            }
        }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsView()
        }
    }
}

// MARK: - Compact width (iPhone)

#if os(iOS)
private struct CompactSessionView: View {
    private enum Tab: Hashable {
        case channels
        case chat
    }

    @Environment(SessionController.self) private var controller
    @State private var selectedTab: Tab = .channels
    @State private var showAudioSettings = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ChannelTreeView()
                    .navigationTitle(serverTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { compactToolbar }
                    .safeAreaInset(edge: .bottom) { VoiceControlBar() }
            }
            .tabItem { Label("Channels", systemImage: "list.bullet.indent") }
            .tag(Tab.channels)

            NavigationStack {
                ChatView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { compactToolbar }
                    .safeAreaInset(edge: .bottom) { VoiceControlBar() }
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            .tag(Tab.chat)
        }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsView()
        }
        .onChange(of: controller.chatTarget) { _, target in
            // "Send Private Message" from the channel list jumps to chat.
            if case .user = target {
                selectedTab = .chat
            }
        }
    }

    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Audio Settings", systemImage: "gearshape") {
                showAudioSettings = true
            }
            DisconnectButton()
        }
    }

    private var serverTitle: String {
        guard let user = controller.ownUser,
            let channel = controller.serverState.channels[user.channelID]
        else { return "Channels" }
        return channel.name.isEmpty ? "Root" : channel.name
    }
}

/// Thumb-reach voice controls pinned above the tab bar on iPhone.
private struct VoiceControlBar: View {
    @Environment(SessionController.self) private var controller
    @AppStorage(AudioPreferences.modeKey) private var transmitMode = TransmitMode.voiceActivity.rawValue

    var body: some View {
        HStack(spacing: 16) {
            MuteButton()
                .frame(width: 44, height: 44)

            DeafenButton()
                .frame(width: 44, height: 44)

            Spacer()

            if transmitMode == TransmitMode.pushToTalk.rawValue {
                PushToTalkButton(style: .bar)
            } else {
                Label(
                    controller.transmitting ? "Transmitting" : "Idle",
                    systemImage: controller.transmitting ? "waveform" : "waveform.slash"
                )
                .font(.caption)
                .foregroundStyle(controller.transmitting ? .green : .secondary)
            }
        }
        .labelStyle(.iconOnly)
        .imageScale(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
#endif

// MARK: - Shared controls

private struct MuteButton: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        Button {
            controller.toggleSelfMute()
        } label: {
            Label(
                controller.selfMuted ? "Unmute" : "Mute",
                systemImage: symbol
            )
            .foregroundStyle(controller.selfMuted ? .red : style)
        }
        .help(controller.selfMuted ? "Unmute microphone" : "Mute microphone")
    }

    private var symbol: String {
        if controller.selfMuted { return "mic.slash.fill" }
        return controller.transmitting ? "mic.fill" : "mic"
    }

    private var style: Color {
        controller.transmitting ? .green : .primary
    }
}

private struct DeafenButton: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        Button {
            controller.toggleSelfDeafen()
        } label: {
            Label(
                controller.selfDeafened ? "Undeafen" : "Deafen",
                systemImage: controller.selfDeafened
                    ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .foregroundStyle(controller.selfDeafened ? .red : .primary)
        }
        .help(controller.selfDeafened ? "Undeafen" : "Deafen (mute + silence others)")
    }
}

private struct DisconnectButton: View {
    @Environment(SessionController.self) private var controller

    var body: some View {
        Button("Disconnect", systemImage: "phone.down.fill") {
            Task { await controller.disconnect() }
        }
    }
}

/// Hold-to-talk button: icon-sized in toolbars, a wide capsule in the
/// compact bottom bar.
private struct PushToTalkButton: View {
    enum Style {
        case toolbar
        case bar
    }

    @Environment(SessionController.self) private var controller
    let style: Style
    @State private var held = false

    var body: some View {
        Group {
            switch style {
            case .toolbar:
                Label("Talk", systemImage: held ? "mic.fill.badge.plus" : "hand.tap")
                    .foregroundStyle(held ? .green : .primary)
                    .padding(.horizontal, 6)
            case .bar:
                Label("Hold to Talk", systemImage: held ? "mic.fill" : "mic")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        held ? AnyShapeStyle(.green.opacity(0.35)) : AnyShapeStyle(.quaternary),
                        in: Capsule()
                    )
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !held {
                        held = true
                        controller.setPTTPressed(true)
                    }
                }
                .onEnded { _ in
                    held = false
                    controller.setPTTPressed(false)
                }
        )
        .help("Hold to talk")
    }
}

/// Server text (welcome, chat) is HTML per the protocol; show it flat.
func plainText(fromHTML html: String) -> String {
    guard html.contains("<") else { return html }
    return html.replacingOccurrences(
        of: "<[^>]+>", with: "", options: .regularExpression
    )
    .replacingOccurrences(of: "&amp;", with: "&")
    .replacingOccurrences(of: "&lt;", with: "<")
    .replacingOccurrences(of: "&gt;", with: ">")
    .replacingOccurrences(of: "&quot;", with: "\"")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}
