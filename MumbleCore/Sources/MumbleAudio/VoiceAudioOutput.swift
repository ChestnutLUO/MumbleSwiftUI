import AVFAudio
import Foundation

/// Plays decoded voice through AVAudioEngine: one ring-buffer-fed source
/// node per speaker, mixed by the engine's main mixer.
///
/// `enqueue(_:for:)` may be called from any thread; render callbacks read
/// concurrently from the audio thread via the lock-protected ring buffers.
public final class VoiceAudioOutput {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat

    private let lock = NSLock()
    private var speakers: [UInt32: SpeakerNode] = [:]

    public init() {
        format = AVAudioFormat(
            standardFormatWithSampleRate: Double(MumbleAudioConstants.sampleRate),
            channels: 1
        )!
    }

    /// Manual rendering support for tests; must be called before `start()`.
    public func enableManualRendering(frameCapacity: AVAudioFrameCount = 4096) throws {
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: frameCapacity)
    }

    public func start() throws {
        // Touching mainMixerNode creates the output chain.
        _ = engine.mainMixerNode
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    /// Renders one block in manual mode (tests only).
    public func renderManually(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else {
            throw NSError(
                domain: "VoiceAudioOutput", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "render status \(status)"])
        }
        return buffer
    }

    /// Queues PCM for a speaker, attaching their node on first use.
    public func enqueue(_ pcm: [Float], for sessionID: UInt32) {
        speakerNode(for: sessionID).write(pcm)
    }

    public func removeSpeaker(_ sessionID: UInt32) {
        let node: SpeakerNode? = withLock {
            speakers.removeValue(forKey: sessionID)
        }
        if let node {
            engine.detach(node.source)
        }
    }

    private func speakerNode(for sessionID: UInt32) -> SpeakerNode {
        if let existing = withLock({ speakers[sessionID] }) {
            return existing
        }
        let node = SpeakerNode()
        let source = AVAudioSourceNode(format: format) {
            [ring = node.ring] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            ring.read(into: out, count: Int(frameCount))
            return noErr
        }
        node.source = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        withLock { speakers[sessionID] = node }
        return node
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Ring buffer + source node for one speaker.
private final class SpeakerNode {
    let ring = PCMRingBuffer(capacity: MumbleAudioConstants.sampleRate)  // 1s
    var source: AVAudioSourceNode!

    func write(_ pcm: [Float]) {
        ring.write(pcm)
    }
}

/// Fixed-capacity single-reader ring buffer. Underruns yield silence;
/// overruns drop the oldest audio.
final class PCMRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            if count == storage.count {
                // Overrun: drop oldest.
                readIndex = (readIndex + 1) % storage.count
                count -= 1
            }
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
            count += 1
        }
    }

    func read(into out: UnsafeMutablePointer<Float>, count requested: Int) {
        lock.lock()
        defer { lock.unlock() }
        let available = min(requested, count)
        for i in 0..<available {
            out[i] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
            count -= 1
        }
        for i in available..<requested {
            out[i] = 0
        }
    }

    var availableSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
