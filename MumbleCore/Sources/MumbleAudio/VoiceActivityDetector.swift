import Foundation

/// Simple level-based voice activity detection with hysteresis and a
/// hold time, mirroring Mumble's amplitude trigger: opens above
/// `openThresholdDB`, stays open until the level has been below
/// `closeThresholdDB` for `holdFrames` consecutive frames.
public struct VoiceActivityDetector: Sendable {
    public var openThresholdDB: Float
    public var closeThresholdDB: Float
    public var holdFrames: Int

    private var open = false
    private var quietFrames = 0

    /// - Parameters:
    ///   - openThresholdDB: RMS level (dBFS) that starts transmission.
    ///   - closeThresholdDB: level below which frames count as quiet;
    ///     defaults 6 dB under the open threshold.
    ///   - holdFrames: quiet frames tolerated before closing (e.g. 20
    ///     10 ms frames ≈ 200 ms hold).
    public init(
        openThresholdDB: Float = -36,
        closeThresholdDB: Float? = nil,
        holdFrames: Int = 20
    ) {
        self.openThresholdDB = openThresholdDB
        self.closeThresholdDB = closeThresholdDB ?? (openThresholdDB - 6)
        self.holdFrames = holdFrames
    }

    /// Whether the detector currently considers speech active.
    public var isOpen: Bool { open }

    /// Feeds one frame; returns whether it should be transmitted.
    public mutating func process(_ pcm: [Float]) -> Bool {
        process(levelDB: Self.rmsDBFS(pcm))
    }

    /// Same, for callers that already computed the frame level.
    public mutating func process(levelDB: Float) -> Bool {
        if levelDB >= openThresholdDB {
            open = true
            quietFrames = 0
        } else if open, levelDB < closeThresholdDB {
            quietFrames += 1
            if quietFrames >= holdFrames {
                open = false
                quietFrames = 0
            }
        } else {
            quietFrames = 0
        }
        return open
    }

    /// RMS level of a frame in dBFS (0 = full scale; silence ≈ -100).
    public static func rmsDBFS(_ pcm: [Float]) -> Float {
        guard !pcm.isEmpty else { return -100 }
        let meanSquare = pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count)
        guard meanSquare > 0 else { return -100 }
        return max(-100, 10 * log10(meanSquare))
    }
}
