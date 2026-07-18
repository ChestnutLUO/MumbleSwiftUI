import Foundation
import MumbleCrypto
import MumbleProtocol
import Network

/// A decoded packet from the 1.5+ protobuf UDP voice protocol.
public enum MumbleVoicePacket: Sendable {
    case audio(MumbleUDP_Audio)
    case ping(MumbleUDP_Ping)
}

/// Type byte prefixed to the protobuf payload on the UDP wire
/// (upstream `MumbleProtocol.h`, `ProtobufMessageType`).
private enum UDPMessageType: UInt8 {
    case audio = 0
    case ping = 1
}

/// Upstream caps UDP datagrams at 1024 bytes (`MAX_UDP_PACKET_SIZE`).
public let mumbleMaxUDPPacketSize = 1024

/// OCB2-encrypted UDP voice channel speaking the 1.5+ protobuf protocol.
///
/// Thread-safety: the crypt state and decoder are only touched on `queue`
/// (Network.framework callbacks are serial there; sends hop onto it too),
/// hence the `@unchecked Sendable`.
public final class MumbleUDPVoiceTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mumble.voice.udp")
    private let crypt: OCB2CryptState

    public let incoming: AsyncStream<MumbleVoicePacket>
    private let incomingContinuation: AsyncStream<MumbleVoicePacket>.Continuation

    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, Error>?

    /// Crypt statistics (good/late/lost/resync), reported in TCP pings.
    public var statistics: OCB2CryptState.Statistics {
        queue.sync { crypt.statistics }
    }

    /// Our current encrypt IV, needed when the server requests a resync.
    public var encryptNonce: Data {
        queue.sync { crypt.encryptNonce }
    }

    /// Applies a resync `CryptSetup`'s server_nonce.
    public func applyServerNonce(_ nonce: Data) {
        queue.sync { _ = crypt.setDecryptNonce(nonce) }
    }

    /// - Parameter cryptSetup: the full-key `CryptSetup` from the TCP
    ///   handshake. Note the swap: the server's `server_nonce` is its
    ///   encrypt IV (our decrypt IV) and vice versa.
    public init?(host: String, port: UInt16, cryptSetup: MumbleProto_CryptSetup) {
        guard
            let crypt = OCB2CryptState(
                key: cryptSetup.key,
                encryptNonce: cryptSetup.clientNonce,
                decryptNonce: cryptSetup.serverNonce
            )
        else { return nil }
        self.crypt = crypt

        let parameters = NWParameters.udp
        parameters.allowFastOpen = true
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 64738,
            using: parameters
        )
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: MumbleVoicePacket.self)
    }

    public func open() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.resumeOpen(with: nil)
            case .failed(let error), .waiting(let error):
                self.resumeOpen(with: error)
                self.connection.cancel()
                self.incomingContinuation.finish()
            case .cancelled:
                self.incomingContinuation.finish()
            default:
                break
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            withStateLock { openContinuation = continuation }
            connection.start(queue: queue)
        }
        receiveNext()
    }

    public func send(_ packet: MumbleVoicePacket) async throws {
        let plaintext = try Self.encodePlaintext(packet)

        let wire = queue.sync { crypt.encrypt(plaintext) }
        guard let wire else { throw MumbleTransportError.connectionFailed("encrypt failed") }
        guard wire.count <= mumbleMaxUDPPacketSize else {
            throw MumbleWireError.payloadTooLarge(length: wire.count, limit: mumbleMaxUDPPacketSize)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: wire,
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

    public func close() {
        connection.cancel()
        incomingContinuation.finish()
    }

    /// Encodes a packet to a plaintext datagram for the TCP `UDPTunnel`
    /// fallback (the UDP path encrypts this same layout).
    public static func encodePlaintext(_ packet: MumbleVoicePacket) throws -> Data {
        switch packet {
        case .audio(let audio):
            return Self.prefixed(.audio, try audio.serializedData())
        case .ping(let ping):
            return Self.prefixed(.ping, try ping.serializedData())
        }
    }

    /// Decodes a plaintext voice datagram — shared by the UDP path (after
    /// decryption) and the TCP `UDPTunnel` fallback (arrives unencrypted).
    public static func decodePlaintext(_ datagram: Data) -> MumbleVoicePacket? {
        guard let first = datagram.first,
            let type = UDPMessageType(rawValue: first)
        else { return nil }
        let payload = datagram.dropFirst()
        switch type {
        case .audio:
            guard let audio = try? MumbleUDP_Audio(serializedBytes: payload) else { return nil }
            return .audio(audio)
        case .ping:
            guard let ping = try? MumbleUDP_Ping(serializedBytes: payload) else { return nil }
            return .ping(ping)
        }
    }

    // MARK: - Internals

    private static func prefixed(_ type: UDPMessageType, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 1)
        data.append(type.rawValue)
        data.append(payload)
        return data
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
                let plaintext = self.crypt.decrypt(data),
                let packet = Self.decodePlaintext(plaintext)
            {
                self.incomingContinuation.yield(packet)
            }
            if error != nil {
                self.incomingContinuation.finish()
                return
            }
            self.receiveNext()
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
}
