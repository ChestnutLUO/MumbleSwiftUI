import Foundation
import Testing
@testable import MumbleAudio

@Suite("Opus codec")
struct OpusCodecTests {
    /// 440 Hz sine at 48 kHz.
    private func sine(samples: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<samples).map { amplitude * sin(2 * .pi * 440 * Float($0) / 48_000) }
    }

    private func energy(_ pcm: [Float]) -> Float {
        pcm.reduce(0) { $0 + $1 * $1 } / Float(max(pcm.count, 1))
    }

    @Test("sine survives an encode/decode round trip", arguments: [480, 960, 1920, 2880])
    func roundTrip(frameSamples: Int) throws {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()

        // Feed a few frames so the codec converges past its warm-up.
        var lastDecoded: [Float] = []
        for i in 0..<5 {
            let pcm = sine(samples: frameSamples).map { $0 * (i == 0 ? 0.1 : 1.0) }
            let packet = try encoder.encode(pcm)
            #expect(packet.count > 0)
            #expect(packet.count < 1000, "voice frames must stay well under the UDP cap")
            lastDecoded = try decoder.decode(packet)
        }

        #expect(lastDecoded.count == frameSamples)
        #expect(energy(lastDecoded) > 0.01, "decoded audio should not be silence")
    }

    @Test("concealment produces audio sized like the last frame")
    func concealment() throws {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()
        for _ in 0..<3 {
            _ = try decoder.decode(try encoder.encode(sine(samples: 960)))
        }
        let concealed = try decoder.conceal()
        #expect(concealed.count == 960)
    }

    @Test("decoder reset survives and keeps decoding")
    func resetKeepsWorking() throws {
        let encoder = try OpusVoiceEncoder()
        let decoder = try OpusVoiceDecoder()
        _ = try decoder.decode(try encoder.encode(sine(samples: 960)))
        decoder.reset()
        let decoded = try decoder.decode(try encoder.encode(sine(samples: 960)))
        #expect(decoded.count == 960)
    }

    @Test("garbage input throws rather than crashing")
    func garbageRejected() throws {
        let decoder = try OpusVoiceDecoder()
        #expect(throws: OpusError.self) {
            _ = try decoder.decode(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }
    }
}
