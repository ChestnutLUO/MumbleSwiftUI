import Foundation
import MumbleProtocol

/// Jitter buffer + Opus decoder for one speaking user: protobuf `Audio`
/// packets in, 48 kHz mono PCM out, pulled one frame at a time.
///
/// Not thread-safe; confine to the voice-receive actor or queue.
public final class SpeakerPipeline {
    public let sessionID: UInt32
    private var jitterBuffer: VoiceJitterBuffer
    private let decoder: OpusVoiceDecoder

    public init(sessionID: UInt32, prebufferFrames: Int = 2) throws {
        self.sessionID = sessionID
        jitterBuffer = VoiceJitterBuffer(prebufferFrames: prebufferFrames)
        decoder = try OpusVoiceDecoder()
    }

    public func receive(_ audio: MumbleUDP_Audio) {
        jitterBuffer.insert(
            frameNumber: audio.frameNumber,
            opusData: audio.opusData,
            isTerminator: audio.isTerminator
        )
    }

    /// Pulls the next frame of PCM for playback. Returns nil when the
    /// stream is idle (caller outputs silence and slows its pull cadence).
    public func nextPCM() -> [Float]? {
        switch jitterBuffer.pop() {
        case .opus(let packet):
            do {
                return try decoder.decode(packet)
            } catch {
                // Undecodable packet — treat as loss.
                return (try? decoder.conceal()) ?? nil
            }
        case .concealment:
            return (try? decoder.conceal()) ?? nil
        case .silence:
            if !jitterBuffer.isPlaying {
                decoder.reset()
            }
            return nil
        }
    }
}
