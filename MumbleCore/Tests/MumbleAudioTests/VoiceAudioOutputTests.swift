import Foundation
import Testing
@testable import MumbleAudio

@Suite("Voice audio output")
struct VoiceAudioOutputTests {
    @Test("ring buffer round-trips, underruns to silence, drops oldest on overrun")
    func ringBuffer() {
        let ring = PCMRingBuffer(capacity: 8)
        ring.write([1, 2, 3])

        var out = [Float](repeating: -1, count: 5)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 5) }
        #expect(out == [1, 2, 3, 0, 0], "missing samples must be silence")

        ring.write((1...10).map(Float.init))  // 10 into capacity 8: drops 1, 2
        var out2 = [Float](repeating: -1, count: 8)
        out2.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) }
        #expect(out2 == [3, 4, 5, 6, 7, 8, 9, 10])
    }

    @Test("engine mixes enqueued speaker PCM into rendered output")
    func manualRender() throws {
        let output = VoiceAudioOutput()
        try output.enableManualRendering()
        try output.start()
        defer { output.stop() }

        // A loud constant signal for one speaker.
        output.enqueue([Float](repeating: 0.8, count: 4096), for: 42)

        let buffer = try output.renderManually(frames: 1024)
        let channel = buffer.floatChannelData![0]
        var energy: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            energy += channel[i] * channel[i]
        }
        #expect(buffer.frameLength == 1024)
        #expect(energy > 0.1, "rendered output should contain the speaker's audio")
    }
}
