import Foundation
import MumbleProtocol

/// Abstraction over the TCP control channel so the session state machine
/// can be tested against a scripted transport without touching the network.
public protocol MumbleControlTransport: Sendable {
    /// Opens the transport. Returns once it is ready to send/receive.
    func open() async throws

    /// Complete frames as they arrive. Finishes when the connection closes
    /// cleanly; throws when it fails.
    var incomingFrames: AsyncThrowingStream<MumbleControlFrame, Error> { get }

    func send(_ frame: MumbleControlFrame) async throws

    func close() async
}

public enum MumbleTransportError: Error, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case notOpen
}

/// How to validate the server's TLS certificate. Mumble servers almost
/// always use self-signed certificates, so clients pin rather than rely
/// on the system trust store.
public enum ServerTrustPolicy: Sendable {
    /// Standard system trust evaluation (only works for CA-signed certs).
    case system
    /// Accept only a certificate whose DER SHA-256 matches. This is the
    /// steady state after trust-on-first-use.
    case pinnedCertificateSHA256(Data)
    /// Accept any certificate. Only for the first connection of a
    /// trust-on-first-use flow (read the hash off the transport afterwards
    /// and pin it) or local development.
    case insecureAcceptAny
}
