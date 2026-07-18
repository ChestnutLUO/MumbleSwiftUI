import CryptoKit
import Foundation
import MumbleProtocol
import Network

/// TCP + TLS control channel over Network.framework.
///
/// Thread-safety: all mutable state is either protected by `lock` or only
/// touched from `queue` (Network.framework invokes every callback there,
/// serially), hence the `@unchecked Sendable`.
public final class TLSControlChannel: MumbleControlTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mumble.control.tls")
    private let trustPolicy: ServerTrustPolicy

    public let incomingFrames: AsyncThrowingStream<MumbleControlFrame, Error>
    private let frameContinuation: AsyncThrowingStream<MumbleControlFrame, Error>.Continuation

    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isOpen = false
    private var observedCertificateSHA256: Data?

    /// Only accessed on `queue` (receive callbacks are serial).
    private var decoder = MumbleControlFrameDecoder()

    /// SHA-256 of the server's leaf certificate (DER), available once the
    /// TLS handshake has run. Persist this to pin on future connections.
    public var serverCertificateSHA256: Data? {
        withStateLock { observedCertificateSHA256 }
    }

    /// NSLock.lock() is unavailable from async contexts; this synchronous
    /// helper is the one place the lock is taken.
    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public init(
        host: String,
        port: UInt16,
        trustPolicy: ServerTrustPolicy,
        clientIdentity: SecIdentity? = nil
    ) {
        self.trustPolicy = trustPolicy

        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        if let clientIdentity, let secIdentity = sec_identity_create(clientIdentity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        }

        // Bridge the certificate observation out of the verify block without
        // capturing self before super.init-equivalent setup completes.
        let policy = trustPolicy
        let certSink = CertificateSink()
        sec_protocol_options_set_verify_block(
            security,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let leafHash = Self.leafCertificateSHA256(of: trust)
                certSink.store(leafHash)
                switch policy {
                case .system:
                    var error: CFError?
                    complete(SecTrustEvaluateWithError(trust, &error))
                case .pinnedCertificateSHA256(let pinned):
                    complete(leafHash == pinned)
                case .insecureAcceptAny:
                    complete(true)
                }
            },
            queue
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 10

        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 64738,
            using: NWParameters(tls: tlsOptions, tcp: tcpOptions)
        )

        (incomingFrames, frameContinuation) = AsyncThrowingStream.makeStream(
            of: MumbleControlFrame.self
        )
        self.certificateSink = certSink
    }

    private let certificateSink: CertificateSink

    public func open() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            withStateLock { openContinuation = continuation }
            connection.start(queue: queue)
        }
        let certificateHash = certificateSink.value
        withStateLock {
            observedCertificateSHA256 = certificateHash
            isOpen = true
        }
        receiveNext()
    }

    public func send(_ frame: MumbleControlFrame) async throws {
        guard withStateLock({ isOpen }) else { throw MumbleTransportError.notOpen }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame.encoded(),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    public func close() async {
        withStateLock { isOpen = false }
        connection.cancel()
        frameContinuation.finish()
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            resumeOpen(with: nil)
        case .failed(let error):
            resumeOpen(with: error)
            frameContinuation.finish(
                throwing: MumbleTransportError.connectionFailed(error.localizedDescription))
        case .waiting(let error):
            // NWConnection parks here and retries indefinitely on TLS
            // rejection or unreachable hosts. For a user-initiated connect
            // that's a failure, not a wait.
            resumeOpen(with: error)
            connection.cancel()
            frameContinuation.finish(
                throwing: MumbleTransportError.connectionFailed(error.localizedDescription))
        case .cancelled:
            frameContinuation.finish()
        default:
            break
        }
    }

    private func resumeOpen(with error: Error?) {
        let continuation = withStateLock {
            let pending = openContinuation
            openContinuation = nil
            return pending
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.decoder.append(data)
                do {
                    while let frame = try self.decoder.next() {
                        self.frameContinuation.yield(frame)
                    }
                } catch {
                    self.frameContinuation.finish(throwing: error)
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.frameContinuation.finish(
                    throwing: MumbleTransportError.connectionFailed(error.localizedDescription))
                return
            }
            if isComplete {
                self.frameContinuation.finish()
                return
            }
            self.receiveNext()
        }
    }

    private static func leafCertificateSHA256(of trust: SecTrust) -> Data? {
        guard
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Data(SHA256.hash(data: der))
    }
}

/// Lock-protected box for the certificate hash observed inside the TLS
/// verify block, which runs before `open()` returns.
private final class CertificateSink: @unchecked Sendable {
    private let lock = NSLock()
    private var hash: Data?

    func store(_ value: Data?) {
        lock.lock()
        hash = value
        lock.unlock()
    }

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return hash
    }
}
