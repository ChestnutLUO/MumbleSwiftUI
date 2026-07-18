@preconcurrency import AVFAudio
import Foundation

/// Captures microphone audio via AVAudioEngine and delivers fixed-size
/// 48 kHz mono float frames suitable for Opus encoding.
///
/// The engine's input tap runs on an audio-owned thread; conversion and
/// slicing are confined to that tap. Frames are handed off through an
/// `AsyncStream` (buffered, so the audio thread never blocks).
public final class VoiceAudioInput: @unchecked Sendable {
    public let frameSamples: Int

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let stateLock = NSLock()
    private var running = false
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// - Parameter frameSamples: capture granularity; the transmit
    ///   pipeline aggregates these into Opus frames.
    public init(frameSamples: Int = MumbleAudioConstants.samplesPer10ms) {
        self.frameSamples = frameSamples
        targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(MumbleAudioConstants.sampleRate),
            channels: 1
        )!
    }

    /// Starts capture. Frames arrive on the returned stream until `stop()`.
    ///
    /// - Parameter voiceProcessing: enables the system voice-processing
    ///   unit (echo cancellation / noise suppression) when available;
    ///   failure to enable it is non-fatal and capture proceeds raw.
    public func start(voiceProcessing: Bool = true) throws -> AsyncStream<[Float]> {
        try withStateLock {
            guard !running else { throw MumbleAudioInputError.alreadyRunning }
            running = true
        }

        let input = engine.inputNode
        if voiceProcessing {
            // Ducks echo from our own output; best-effort (unsupported
            // on some devices/virtual inputs).
            try? input.setVoiceProcessingEnabled(true)
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            withStateLock { running = false }
            throw MumbleAudioInputError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            withStateLock { running = false }
            throw MumbleAudioInputError.formatConversionUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(64))
        withStateLock { self.continuation = continuation }

        let slicer = PCMFrameSlicer(frameSamples: frameSamples)
        let ratio = targetFormat.sampleRate / hardwareFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) {
            [targetFormat] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard
                let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = converted.floatChannelData else { return }
            let samples = Array(
                UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
            for frame in slicer.append(samples) {
                continuation.yield(frame)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            withStateLock {
                running = false
                self.continuation = nil
            }
            continuation.finish()
            throw error
        }
        return stream
    }

    public func stop() {
        let continuation: AsyncStream<[Float]>.Continuation? = withStateLock {
            guard running else { return nil }
            running = false
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}

public enum MumbleAudioInputError: Error, Sendable {
    case alreadyRunning
    case noInputDevice
    case formatConversionUnavailable
}

/// Re-chunks arbitrarily sized sample batches into fixed-size frames.
/// Not thread-safe; confine to the capture tap.
final class PCMFrameSlicer {
    private let frameSamples: Int
    private var pending: [Float] = []

    init(frameSamples: Int) {
        self.frameSamples = frameSamples
        pending.reserveCapacity(frameSamples * 2)
    }

    func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        guard pending.count >= frameSamples else { return [] }
        var frames: [[Float]] = []
        var start = 0
        while pending.count - start >= frameSamples {
            frames.append(Array(pending[start..<(start + frameSamples)]))
            start += frameSamples
        }
        pending.removeFirst(start)
        return frames
    }

    /// Remaining samples not yet forming a full frame.
    var pendingSamples: Int { pending.count }
}
