import MumbleConnection
import SwiftUI

struct SessionView: View {
    @Environment(SessionController.self) private var controller

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
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect", systemImage: "phone.down.fill") {
                    Task { await controller.disconnect() }
                }
            }
        }
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
