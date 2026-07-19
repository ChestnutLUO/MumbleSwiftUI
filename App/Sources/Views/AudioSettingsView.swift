import SwiftUI

/// Transmit settings: mode, voice-activity threshold (with a live level
/// meter), and Opus bitrate. Persisted via UserDefaults and applied to
/// the live session immediately.
struct AudioSettingsView: View {
    @Environment(SessionController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AudioPreferences.modeKey)
    private var mode = TransmitMode.voiceActivity.rawValue
    @AppStorage(AudioPreferences.bitrateKey)
    private var bitrate = 64_000
    @AppStorage(AudioPreferences.vadThresholdKey)
    private var vadThresholdDB = -36.0

    private static let bitrates = [24_000, 40_000, 64_000, 96_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Transmission", selection: $mode) {
                    ForEach(TransmitMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }

                Picker("Quality", selection: $bitrate) {
                    ForEach(Self.bitrates, id: \.self) { rate in
                        Text("\(rate / 1000) kb/s").tag(rate)
                    }
                }

                if mode == TransmitMode.voiceActivity.rawValue {
                    LabeledContent("Sensitivity") {
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $vadThresholdDB, in: -60...(-10)) {
                                EmptyView()
                            } minimumValueLabel: {
                                Text("Sensitive").font(.caption2)
                            } maximumValueLabel: {
                                Text("Loud only").font(.caption2)
                            }
                            levelMeter
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if controller.transmitting {
                    Label("Transmitting", systemImage: "mic.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        #if os(macOS)
            .frame(width: 420)
        #endif
        .onChange(of: mode) { controller.applyAudioPreferences() }
        .onChange(of: bitrate) { controller.applyAudioPreferences() }
        .onChange(of: vadThresholdDB) { controller.applyAudioPreferences() }
    }

    /// Live mic level against the VAD threshold.
    private var levelMeter: some View {
        GeometryReader { geometry in
            let level = normalized(Double(controller.inputLevelDB))
            let threshold = normalized(vadThresholdDB)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(controller.inputLevelDB >= Float(vadThresholdDB) ? .green : .gray)
                    .frame(width: geometry.size.width * level)
                Rectangle()
                    .fill(.red)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * threshold)
            }
        }
        .frame(height: 8)
    }

    /// Maps -60…0 dBFS onto 0…1.
    private func normalized(_ db: Double) -> Double {
        min(1, max(0, (db + 60) / 60))
    }
}
