import Foundation
import Testing
@testable import MumbleAudio

@Suite("Voice jitter buffer")
struct VoiceJitterBufferTests {
    private func frame(_ n: Int) -> Data { Data("frame-\(n)".utf8) }

    @Test("prebuffers before playing, then yields in order")
    func prebuffer() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 2)
        #expect(buffer.pop() == .silence)

        buffer.insert(frameNumber: 10, opusData: frame(10), isTerminator: false)
        #expect(buffer.pop() == .silence, "one frame is below the prebuffer threshold")

        buffer.insert(frameNumber: 11, opusData: frame(11), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(10)))
        #expect(buffer.pop() == .opus(frame(11)))
    }

    @Test("out-of-order arrival is reordered")
    func reorder() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 2)
        buffer.insert(frameNumber: 1, opusData: frame(1), isTerminator: false)
        buffer.insert(frameNumber: 0, opusData: frame(0), isTerminator: false)
        buffer.insert(frameNumber: 3, opusData: frame(3), isTerminator: false)
        buffer.insert(frameNumber: 2, opusData: frame(2), isTerminator: false)

        #expect(buffer.pop() == .opus(frame(0)))
        #expect(buffer.pop() == .opus(frame(1)))
        #expect(buffer.pop() == .opus(frame(2)))
        #expect(buffer.pop() == .opus(frame(3)))
    }

    @Test("gaps produce concealment, then resume")
    func gapConcealment() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 1)
        buffer.insert(frameNumber: 0, opusData: frame(0), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(0)))

        // Frame 1 lost; frame 2 arrives.
        buffer.insert(frameNumber: 2, opusData: frame(2), isTerminator: false)
        #expect(buffer.pop() == .concealment)
        #expect(buffer.pop() == .opus(frame(2)))
    }

    @Test("terminator drains then goes idle and accepts a new stream")
    func terminatorAndRestart() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 2)
        buffer.insert(frameNumber: 0, opusData: frame(0), isTerminator: false)
        buffer.insert(frameNumber: 1, opusData: frame(1), isTerminator: true)

        #expect(buffer.pop() == .opus(frame(0)))
        #expect(buffer.pop() == .opus(frame(1)))
        #expect(buffer.pop() == .silence)
        #expect(!buffer.isPlaying)

        // New transmission restarts numbering.
        buffer.insert(frameNumber: 0, opusData: frame(100), isTerminator: false)
        buffer.insert(frameNumber: 1, opusData: frame(101), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(100)))
    }

    @Test("dry buffer waits instead of concealing forever")
    func dryStream() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 1)
        buffer.insert(frameNumber: 0, opusData: frame(0), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(0)))
        #expect(buffer.pop() == .silence, "no later frames buffered — wait, don't conceal")

        buffer.insert(frameNumber: 1, opusData: frame(1), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(1)))
    }

    @Test("runaway depth skips ahead instead of growing latency")
    func depthCap() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 2, maxDepth: 5)
        for n in 0..<20 {
            buffer.insert(frameNumber: UInt64(n), opusData: frame(n), isTerminator: false)
        }
        // The buffer must have dropped old frames rather than hold all 20.
        guard case .opus(let data) = buffer.pop() else {
            Issue.record("expected audio after skip-ahead")
            return
        }
        let played = String(decoding: data, as: UTF8.self)
        let number = Int(played.dropFirst("frame-".count))!
        #expect(number > 10, "expected skip toward the newest frames, got \(played)")
    }

    @Test("frames older than the playhead are ignored")
    func staleFrames() {
        var buffer = VoiceJitterBuffer(prebufferFrames: 1)
        buffer.insert(frameNumber: 5, opusData: frame(5), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(5)))
        buffer.insert(frameNumber: 3, opusData: frame(3), isTerminator: false)
        buffer.insert(frameNumber: 6, opusData: frame(6), isTerminator: false)
        #expect(buffer.pop() == .opus(frame(6)))
    }
}
