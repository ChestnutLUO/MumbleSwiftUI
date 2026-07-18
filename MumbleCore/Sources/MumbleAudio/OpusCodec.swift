import COpus
import COpusShim
import Foundation

public enum OpusError: Error, Sendable {
    case creationFailed(Int32)
    case decodeFailed(Int32)
    case encodeFailed(Int32)
    case invalidFrameSize(Int)
}

/// Mumble voice is Opus at 48 kHz mono; playback may upmix locally.
public enum MumbleAudioConstants {
    public static let sampleRate = 48_000
    public static let channels = 1
    /// 10ms — the granularity Mumble frames are multiples of.
    public static let samplesPer10ms = 480
    /// Opus caps a packet at 120ms of audio.
    public static let maxSamplesPerPacket = 5760
}

/// One decoder per speaking user (Opus decoders are stateful across a
/// stream). Not thread-safe; confine to the speaker's pipeline.
public final class OpusVoiceDecoder {
    private let decoder: OpaquePointer
    /// Samples in the last successfully decoded packet, used to size
    /// packet-loss concealment output.
    private var lastFrameSamples = MumbleAudioConstants.samplesPer10ms * 2

    public init() throws {
        var error: Int32 = 0
        guard
            let decoder = opus_decoder_create(
                Int32(MumbleAudioConstants.sampleRate),
                Int32(MumbleAudioConstants.channels),
                &error
            ), error == OPUS_OK
        else { throw OpusError.creationFailed(error) }
        self.decoder = decoder
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Decodes one Opus packet to 48 kHz mono float PCM.
    public func decode(_ packet: Data) throws -> [Float] {
        var pcm = [Float](repeating: 0, count: MumbleAudioConstants.maxSamplesPerPacket)
        let decoded = packet.withUnsafeBytes { raw in
            opus_decode_float(
                decoder,
                raw.bindMemory(to: UInt8.self).baseAddress,
                opus_int32(packet.count),
                &pcm,
                Int32(MumbleAudioConstants.maxSamplesPerPacket),
                0
            )
        }
        guard decoded > 0 else { throw OpusError.decodeFailed(decoded) }
        lastFrameSamples = Int(decoded)
        return Array(pcm[0..<Int(decoded)])
    }

    /// Produces packet-loss concealment audio for one missing frame.
    public func conceal() throws -> [Float] {
        var pcm = [Float](repeating: 0, count: lastFrameSamples)
        let decoded = opus_decode_float(decoder, nil, 0, &pcm, Int32(lastFrameSamples), 0)
        guard decoded > 0 else { throw OpusError.decodeFailed(decoded) }
        return Array(pcm[0..<Int(decoded)])
    }

    /// Resets decoder state between transmissions (after a terminator).
    public func reset() {
        mumble_opus_decoder_reset(decoder)
    }
}

/// Voice-tuned Opus encoder for the send path. Not thread-safe; confine
/// to the transmit pipeline.
public final class OpusVoiceEncoder {
    private let encoder: OpaquePointer

    /// - Parameter bitrate: target bits/second (Mumble's usual range is
    ///   24k–96k; upstream defaults to ~64k with VBR on).
    public init(bitrate: Int = 64_000) throws {
        var error: Int32 = 0
        guard
            let encoder = opus_encoder_create(
                Int32(MumbleAudioConstants.sampleRate),
                Int32(MumbleAudioConstants.channels),
                OPUS_APPLICATION_VOIP,
                &error
            ), error == OPUS_OK
        else { throw OpusError.creationFailed(error) }
        self.encoder = encoder
        mumble_opus_encoder_set_signal_voice(encoder)
        mumble_opus_encoder_set_vbr(encoder, 1)
        mumble_opus_encoder_set_bitrate(encoder, opus_int32(bitrate))
        // Tolerate mild UDP loss without retransmission.
        mumble_opus_encoder_set_inband_fec(encoder, 1)
        mumble_opus_encoder_set_packet_loss_perc(encoder, 15)
    }

    /// Current target bitrate in bits/second.
    public var bitrate: Int {
        var value: opus_int32 = 0
        mumble_opus_encoder_get_bitrate(encoder, &value)
        return Int(value)
    }

    /// Changes the target bitrate mid-stream (takes effect next frame).
    public func setBitrate(_ bitsPerSecond: Int) {
        mumble_opus_encoder_set_bitrate(encoder, opus_int32(bitsPerSecond))
    }

    /// Resets encoder state between transmissions.
    public func reset() {
        mumble_opus_encoder_reset(encoder)
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    /// Encodes one frame of 48 kHz mono PCM. The sample count must be a
    /// valid Opus frame size (e.g. 480/960/1920/2880 for 10/20/40/60 ms).
    public func encode(_ pcm: [Float]) throws -> Data {
        var packet = [UInt8](repeating: 0, count: 4000)
        let written = opus_encode_float(
            encoder, pcm, Int32(pcm.count), &packet, opus_int32(packet.count))
        guard written > 0 else { throw OpusError.encodeFailed(written) }
        return Data(packet[0..<Int(written)])
    }
}
