import Foundation
import MumbleProtocol
import Testing

@testable import MumbleAudio

@Suite("PCM frame slicer")
struct PCMFrameSlicerTests {
    @Test func unevenChunksProduceExactFrames() {
        let slicer = PCMFrameSlicer(frameSamples: 480)
        var frames: [[Float]] = []
        // 3×400 = 1200 samples → 2 full frames + 240 pending.
        for chunk in 0..<3 {
            frames.append(contentsOf: slicer.append(
                [Float](repeating: Float(chunk), count: 400)))
        }
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.count == 480 })
        #expect(slicer.pendingSamples == 240)
        // Sample continuity across the chunk boundary.
        #expect(frames[0][399] == 0)
        #expect(frames[0][400] == 1)
    }

    @Test func largeChunkYieldsMultipleFrames() {
        let slicer = PCMFrameSlicer(frameSamples: 480)
        let frames = slicer.append([Float](repeating: 0.5, count: 480 * 3 + 7))
        #expect(frames.count == 3)
        #expect(slicer.pendingSamples == 7)
    }
}

@Suite("Voice activity detector")
struct VoiceActivityDetectorTests {
    private let loud = [Float](repeating: 0.5, count: 480)  // ≈ -6 dBFS
    private let quiet = [Float](repeating: 0.001, count: 480)  // ≈ -60 dBFS

    @Test func opensOnSpeechAndHoldsThroughShortPauses() {
        var vad = VoiceActivityDetector(openThresholdDB: -36, holdFrames: 3)
        let sequence = [quiet, loud, quiet, quiet, quiet].map { vad.process($0) }
        // Closed → opens on speech → holds through a short pause →
        // closes once the hold expires.
        #expect(sequence == [false, true, true, true, false])
    }

    @Test func speechDuringHoldRearms() {
        var vad = VoiceActivityDetector(openThresholdDB: -36, holdFrames: 2)
        let sequence = [loud, quiet, loud, quiet, quiet].map { vad.process($0) }
        #expect(sequence == [true, true, true, true, false])
    }

    @Test func rmsLevels() {
        #expect(VoiceActivityDetector.rmsDBFS([]) == -100)
        #expect(VoiceActivityDetector.rmsDBFS([0, 0, 0]) == -100)
        let fullScale = VoiceActivityDetector.rmsDBFS([Float](repeating: 1, count: 480))
        #expect(abs(fullScale) < 0.01)
    }
}

@Suite("Opus encoder controls")
struct OpusEncoderControlTests {
    @Test func bitrateRoundTrips() throws {
        let encoder = try OpusVoiceEncoder(bitrate: 40_000)
        #expect(encoder.bitrate == 40_000)
        encoder.setBitrate(96_000)
        #expect(encoder.bitrate == 96_000)
    }
}

@Suite("Voice transmit pipeline")
struct VoiceTransmitPipelineTests {
    private func sine(_ samples: Int, frequency: Float = 440) -> [Float] {
        (0..<samples).map {
            0.5 * sin(2 * .pi * frequency * Float($0) / Float(MumbleAudioConstants.sampleRate))
        }
    }

    @Test func rejectsInvalidFrameSize() {
        #expect(throws: OpusError.self) {
            _ = try VoiceTransmitPipeline(frameSamples: 500)
        }
    }

    @Test func aggregatesCaptureFramesIntoOpusPackets() throws {
        let pipeline = try VoiceTransmitPipeline(frameSamples: 960)
        var packets: [MumbleUDP_Audio] = []
        // 5 × 10ms in → 2 × 20ms packets out, 10ms pending.
        for chunk in 0..<5 {
            packets.append(contentsOf: try pipeline.encode(
                sine(480, frequency: 440 + Float(chunk))))
        }
        #expect(packets.count == 2)
        #expect(packets.map(\.frameNumber) == [0, 1])
        #expect(packets.allSatisfy { !$0.isTerminator && !$0.opusData.isEmpty })

        let terminator = try #require(try pipeline.endTransmission())
        #expect(terminator.isTerminator)
        #expect(terminator.frameNumber == 2)

        // Idle pipeline produces no terminator.
        #expect(try pipeline.endTransmission() == nil)

        // Next transmission keeps the frame counter monotonic.
        let next = try pipeline.encode(sine(960))
        #expect(next.map(\.frameNumber) == [3])
    }

    @Test func encodedVoiceSurvivesDecode() throws {
        let pipeline = try VoiceTransmitPipeline(bitrate: 64_000, frameSamples: 960)
        let decoder = try OpusVoiceDecoder()

        var decoded: [Float] = []
        for _ in 0..<10 {
            for packet in try pipeline.encode(sine(960)) {
                decoded.append(contentsOf: try decoder.decode(packet.opusData))
            }
        }
        #expect(decoded.count == 9600)
        // Energy in the later frames (post codec warmup) should be
        // comparable to a 0.5-amplitude sine (RMS ≈ -9 dBFS).
        let tail = Array(decoded.suffix(4800))
        let level = VoiceActivityDetector.rmsDBFS(tail)
        #expect(level > -15 && level < -3)
    }

    @Test func packetsFitInUDPBudget() throws {
        let pipeline = try VoiceTransmitPipeline(bitrate: 96_000, frameSamples: 2880)
        for _ in 0..<5 {
            for packet in try pipeline.encode(sine(2880)) {
                // Leave headroom for the protobuf wrapper + crypt overhead.
                #expect(packet.opusData.count < 960)
            }
        }
    }
}
