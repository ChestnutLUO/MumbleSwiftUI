import Foundation
import MumbleProtocol
@testable import MumbleConnection

/// Scripted in-memory transport. `AsyncThrowingStream` buffers, so tests can
/// preload the whole server-side script with `serverSends(_:)` before the
/// session connects, then assert on `sentMessages` afterwards.
actor MockTransport: MumbleControlTransport {
    private(set) var sentMessages: [MumbleControlMessage] = []
    private(set) var closed = false
    private var failOnOpen: Error?

    nonisolated let incomingFrames: AsyncThrowingStream<MumbleControlFrame, Error>
    private nonisolated let incoming: AsyncThrowingStream<MumbleControlFrame, Error>.Continuation

    init() {
        (incomingFrames, incoming) = AsyncThrowingStream.makeStream(of: MumbleControlFrame.self)
    }

    func setFailOnOpen(_ error: Error) {
        failOnOpen = error
    }

    func open() async throws {
        if let failOnOpen { throw failOnOpen }
    }

    func send(_ frame: MumbleControlFrame) async throws {
        guard let message = try MumbleControlMessage(frame: frame) else { return }
        sentMessages.append(message)
    }

    func close() async {
        closed = true
        incoming.finish()
    }

    /// Injects a server→client message into the session.
    func serverSends(_ message: MumbleControlMessage) throws {
        incoming.yield(try message.frame())
    }

    func serverCloses(error: Error? = nil) {
        if let error {
            incoming.finish(throwing: error)
        } else {
            incoming.finish()
        }
    }
}
