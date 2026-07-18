import COpus
import Foundation

public enum OpusError: Error, Sendable {
    case creationFailed(Int32)
    case decodeFailed(Int32)
    case encodeFailed(Int32)
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
    private var decoder: OpaquePointer
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
        // OPUS_RESET_STATE is a variadic ctl macro Swift can't call;
        // recreating costs little and only happens at end-of-transmission.
        var error: Int32 = 0
        if let fresh = opus_decoder_create(
            Int32(MumbleAudioConstants.sampleRate),
            Int32(MumbleAudioConstants.channels),
            &error
        ), error == OPUS_OK {
            opus_decoder_destroy(decoder)
            decoder = fresh
        }
    }
}

/// Voice-tuned Opus encoder (used for the send path and tests). Library
/// defaults are sensible for VoIP; bitrate ctl needs a C shim (variadic)
/// and lands with the send-path work.
public final class OpusVoiceEncoder {
    private let encoder: OpaquePointer

    public init() throws {
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
