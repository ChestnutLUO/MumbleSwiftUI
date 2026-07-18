import Foundation

/// Reorders incoming voice frames per speaker and smooths network jitter.
///
/// Purely deterministic (no clocks): the audio output pulls one frame per
/// playback tick via ``pop()``, and the buffer answers with real data,
/// a concealment request, or silence.
public struct VoiceJitterBuffer: Sendable {
    public enum Output: Equatable, Sendable {
        /// Play this Opus packet.
        case opus(Data)
        /// Frame missing — ask the decoder for loss concealment.
        case concealment
        /// Stream idle (not started, dried up, or ended).
        case silence
    }

    /// Frames buffered before playback starts, absorbing network jitter.
    private let prebufferFrames: Int
    /// Beyond this depth the buffer skips ahead instead of adding latency.
    private let maxDepth: Int
    /// Consecutive missing frames tolerated before declaring the stream dry.
    private let maxConcealment: Int

    private var pending: [UInt64: Data] = [:]
    private var nextFrame: UInt64 = 0
    private var playing = false
    private var terminated = false
    private var concealedRun = 0

    public init(prebufferFrames: Int = 2, maxDepth: Int = 25, maxConcealment: Int = 5) {
        self.prebufferFrames = prebufferFrames
        self.maxDepth = maxDepth
        self.maxConcealment = maxConcealment
    }

    public var isPlaying: Bool { playing }

    public mutating func insert(frameNumber: UInt64, opusData: Data, isTerminator: Bool) {
        if terminated {
            // New transmission after end-of-stream: start fresh.
            resetStream()
        }
        if playing && frameNumber < nextFrame {
            return  // Too late; its slot already played (or was concealed).
        }
        pending[frameNumber] = opusData
        if isTerminator {
            terminated = true
        }
        if pending.count > maxDepth, let newest = pending.keys.max() {
            // Runaway latency — jump forward, keeping a prebuffer's worth.
            let target = newest >= UInt64(prebufferFrames) ? newest - UInt64(prebufferFrames) : 0
            for key in pending.keys where key < target {
                pending.removeValue(forKey: key)
            }
            nextFrame = max(nextFrame, pending.keys.min() ?? target)
        }
    }

    public mutating func pop() -> Output {
        if !playing {
            let enoughBuffered = pending.count >= prebufferFrames
            let streamComplete = terminated && !pending.isEmpty
            guard enoughBuffered || streamComplete else { return .silence }
            playing = true
            nextFrame = pending.keys.min() ?? 0
        }

        if let data = pending.removeValue(forKey: nextFrame) {
            nextFrame += 1
            concealedRun = 0
            return .opus(data)
        }

        if terminated && pending.isEmpty {
            resetStream()
            return .silence
        }

        if pending.keys.contains(where: { $0 > nextFrame }), concealedRun < maxConcealment {
            // Gap with later frames waiting — conceal and move on.
            nextFrame += 1
            concealedRun += 1
            return .concealment
        }

        if concealedRun >= maxConcealment {
            // Give up on the gap; jump to the oldest buffered frame.
            if let oldest = pending.keys.min() {
                nextFrame = oldest
                concealedRun = 0
                return pop()
            }
        }

        // Dried up mid-stream: wait silently for the network to catch up.
        playing = false
        return .silence
    }

    private mutating func resetStream() {
        pending.removeAll()
        playing = false
        terminated = false
        concealedRun = 0
        nextFrame = 0
    }
}
