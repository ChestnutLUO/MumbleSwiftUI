import MumbleConnection
import SwiftUI

struct SessionView: View {
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
            ToolbarItem(placement: .status) {
                if let info = controller.syncInfo, !info.welcomeText.isEmpty {
                    Text(plainText(fromHTML: info.welcomeText))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if transmitMode == TransmitMode.pushToTalk.rawValue {
                    PushToTalkButton()
                }
                Button {
                    controller.toggleSelfMute()
                } label: {
                    Label(
                        controller.selfMuted ? "Unmute" : "Mute",
                        systemImage: micSymbol
                    )
                    .foregroundStyle(controller.selfMuted ? .red : micStyle)
                }
                .help(controller.selfMuted ? "Unmute microphone" : "Mute microphone")

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

                Button("Audio Settings", systemImage: "gearshape") {
                    showAudioSettings = true
                }

                Button("Disconnect", systemImage: "phone.down.fill") {
                    Task { await controller.disconnect() }
                }
            }
        }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsView()
        }
    }

    private var micSymbol: String {
        if controller.selfMuted { return "mic.slash.fill" }
        return controller.transmitting ? "mic.fill" : "mic"
    }

    private var micStyle: Color {
        controller.transmitting ? .green : .primary
    }
}

/// Hold-to-talk toolbar button for push-to-talk mode.
private struct PushToTalkButton: View {
    @Environment(SessionController.self) private var controller
    @State private var held = false

    var body: some View {
        Label("Talk", systemImage: held ? "mic.fill.badge.plus" : "hand.tap")
            .foregroundStyle(held ? .green : .primary)
            .padding(.horizontal, 6)
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
