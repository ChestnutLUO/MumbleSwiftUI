import Foundation
import MumbleProtocol

/// Turns captured PCM into protobuf `Audio` packets: aggregates 10 ms
/// capture frames into the configured Opus frame size, encodes, and
/// stamps monotonic frame numbers. Emits a terminator packet at
/// end-of-transmission so receivers flush their jitter buffers.
///
/// Not thread-safe; confine to the transmit actor.
public final class VoiceTransmitPipeline {
    /// Opus frame sizes valid for Mumble voice (10/20/40/60 ms at 48 kHz).
    public static let validFrameSamples: Set<Int> = [480, 960, 1920, 2880]

    private let encoder: OpusVoiceEncoder
    private let frameSamples: Int
    private var pending: [Float] = []
    private var frameNumber: UInt64 = 0
    private var inTransmission = false

    public init(bitrate: Int = 64_000, frameSamples: Int = 960) throws {
        guard Self.validFrameSamples.contains(frameSamples) else {
            throw OpusError.invalidFrameSize(frameSamples)
        }
        self.frameSamples = frameSamples
        encoder = try OpusVoiceEncoder(bitrate: bitrate)
        pending.reserveCapacity(frameSamples * 2)
    }

    public func setBitrate(_ bitsPerSecond: Int) {
        encoder.setBitrate(bitsPerSecond)
    }

    /// Feeds captured PCM; returns zero or more ready-to-send packets.
    public func encode(_ pcm: [Float], target: UInt32 = 0) throws -> [MumbleUDP_Audio] {
        inTransmission = true
        pending.append(contentsOf: pcm)
        var packets: [MumbleUDP_Audio] = []
        var start = 0
        while pending.count - start >= frameSamples {
            let frame = Array(pending[start..<(start + frameSamples)])
            start += frameSamples
            packets.append(try packet(for: encoder.encode(frame), target: target))
        }
        pending.removeFirst(start)
        return packets
    }

    /// Ends the current transmission: encodes any remainder (zero-padded
    /// to a full frame, or one frame of silence) flagged `is_terminator`,
    /// then resets encoder state for the next transmission.
    public func endTransmission(target: UInt32 = 0) throws -> MumbleUDP_Audio? {
        guard inTransmission else { return nil }
        var frame = pending
        pending.removeAll(keepingCapacity: true)
        frame.append(contentsOf: [Float](repeating: 0, count: frameSamples - frame.count))
        var terminator = try packet(for: encoder.encode(frame), target: target)
        terminator.isTerminator = true
        encoder.reset()
        inTransmission = false
        return terminator
    }

    private func packet(for opusData: Data, target: UInt32) throws -> MumbleUDP_Audio {
        var audio = MumbleUDP_Audio()
        audio.target = target
        audio.frameNumber = frameNumber
        audio.opusData = opusData
        frameNumber += 1
        return audio
    }
}
