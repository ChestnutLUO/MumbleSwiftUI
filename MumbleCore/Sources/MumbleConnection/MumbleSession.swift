import Foundation
import MumbleProtocol

public struct MumbleSessionConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String?
    public var accessTokens: [String]
    public var trustPolicy: ServerTrustPolicy
    public var clientVersion: MumbleVersion
    public var clientRelease: String
    /// Seconds between keepalive pings (server kicks after 30 s silence).
    public var pingInterval: Duration
    /// Deadline for the handshake to reach ServerSync.
    public var connectTimeout: Duration

    public init(
        host: String,
        port: UInt16 = 64738,
        username: String,
        password: String? = nil,
        accessTokens: [String] = [],
        trustPolicy: ServerTrustPolicy = .system,
        clientVersion: MumbleVersion = MumbleVersion(major: 1, minor: 5, patch: 0),
        clientRelease: String = "MumbleSwiftUI",
        pingInterval: Duration = .seconds(5),
        connectTimeout: Duration = .seconds(10)
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.accessTokens = accessTokens
        self.trustPolicy = trustPolicy
        self.clientVersion = clientVersion
        self.clientRelease = clientRelease
        self.pingInterval = pingInterval
        self.connectTimeout = connectTimeout
    }
}

public enum MumbleSessionError: Error, Equatable, Sendable {
    case rejected(type: MumbleProto_Reject.RejectType, reason: String)
    case connectionClosedDuringHandshake
    case timeout
    case alreadyConnected
}

/// Facts delivered by `ServerSync` when the handshake completes.
public struct MumbleServerSyncInfo: Equatable, Sendable {
    /// Our own session id.
    public var sessionID: UInt32
    /// Maximum audio bandwidth in bits/s the server allows.
    public var maxBandwidth: UInt32
    public var welcomeText: String
}

public enum MumbleSessionEvent: Sendable {
    /// Channel/user tree changed; a fresh snapshot is attached.
    case serverStateChanged(MumbleServerState)
    case textMessage(MumbleProto_TextMessage)
    case permissionDenied(MumbleProto_PermissionDenied)
    /// Connection ended; nil error means a clean disconnect.
    case disconnected(Error?)
}

/// Drives one connection to a Mumble server: handshake through ServerSync,
/// keepalive pings, and the live channel/user model.
public actor MumbleSession {
    public let configuration: MumbleSessionConfiguration

    public private(set) var state = MumbleServerState()
    public private(set) var syncInfo: MumbleServerSyncInfo?
    public private(set) var serverVersion: MumbleVersion?
    /// CryptSetup key material, held for the phase-3 UDP voice channel.
    public private(set) var cryptSetup: MumbleProto_CryptSetup?

    public let events: AsyncStream<MumbleSessionEvent>
    private let eventContinuation: AsyncStream<MumbleSessionEvent>.Continuation

    private let transport: any MumbleControlTransport
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var syncContinuation: CheckedContinuation<MumbleServerSyncInfo, Error>?
    /// Handshake outcome that arrived before `awaitServerSync` installed its
    /// continuation (e.g. an instant Reject); consumed by the next await.
    private var bufferedHandshakeResult: Result<MumbleServerSyncInfo, Error>?
    private var isConnected = false

    /// Connects over TLS. For tests, use `init(configuration:transport:)`.
    public init(configuration: MumbleSessionConfiguration) {
        self.init(
            configuration: configuration,
            transport: TLSControlChannel(
                host: configuration.host,
                port: configuration.port,
                trustPolicy: configuration.trustPolicy
            )
        )
    }

    public init(configuration: MumbleSessionConfiguration, transport: any MumbleControlTransport) {
        self.configuration = configuration
        self.transport = transport
        (events, eventContinuation) = AsyncStream.makeStream(of: MumbleSessionEvent.self)
    }

    /// Opens the transport, performs the handshake, and returns once the
    /// server has sent ServerSync. Throws on Reject, timeout, or transport
    /// failure.
    @discardableResult
    public func connect() async throws -> MumbleServerSyncInfo {
        guard !isConnected else { throw MumbleSessionError.alreadyConnected }
        isConnected = true

        do {
            try await transport.open()

            receiveTask = Task { await self.receiveLoop() }

            var version = MumbleProto_Version()
            version.versionV1 = configuration.clientVersion.v1
            version.versionV2 = configuration.clientVersion.v2
            version.release = configuration.clientRelease
            #if os(macOS)
                version.os = "macOS"
            #else
                version.os = "iOS"
            #endif
            try await send(.version(version))

            var auth = MumbleProto_Authenticate()
            auth.username = configuration.username
            if let password = configuration.password {
                auth.password = password
            }
            auth.tokens = configuration.accessTokens
            auth.opus = true
            auth.clientType = 0
            try await send(.authenticate(auth))

            let timeoutTask = Task { [weak self, timeout = configuration.connectTimeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.handshakeTimedOut()
            }
            defer { timeoutTask.cancel() }

            let info = try await awaitServerSync()
            startPingLoop()
            return info
        } catch {
            await teardown(error: error)
            throw error
        }
    }

    public func send(_ message: MumbleControlMessage) async throws {
        try await transport.send(try message.frame())
    }

    public func sendTextMessage(_ text: String, toChannel channelID: UInt32) async throws {
        var message = MumbleProto_TextMessage()
        message.channelID = [channelID]
        message.message = text
        try await send(.textMessage(message))
    }

    public func joinChannel(_ channelID: UInt32) async throws {
        guard let sessionID = syncInfo?.sessionID else { return }
        var userState = MumbleProto_UserState()
        userState.session = sessionID
        userState.channelID = channelID
        try await send(.userState(userState))
    }

    public func disconnect() async {
        await teardown(error: nil)
    }

    // MARK: - Internals

    private func receiveLoop() async {
        do {
            for try await frame in transport.incomingFrames {
                guard let message = try? MumbleControlMessage(frame: frame) else { continue }
                handle(message)
            }
            finishHandshakeIfPending(with: .failure(MumbleSessionError.connectionClosedDuringHandshake))
            if isConnected {
                eventContinuation.yield(.disconnected(nil))
                await teardown(error: nil)
            }
        } catch {
            finishHandshakeIfPending(with: .failure(error))
            if isConnected {
                eventContinuation.yield(.disconnected(error))
                await teardown(error: error)
            }
        }
    }

    private func handle(_ message: MumbleControlMessage) {
        switch message {
        case .version(let version):
            serverVersion = version.hasVersionV2
                ? MumbleVersion(v2: version.versionV2)
                : MumbleVersion(v1: version.versionV1)
        case .cryptSetup(let crypt):
            // Full setup replaces; a nonce-only message is a resync update.
            if crypt.hasKey {
                cryptSetup = crypt
            } else if var existing = cryptSetup {
                if crypt.hasServerNonce { existing.serverNonce = crypt.serverNonce }
                if crypt.hasClientNonce { existing.clientNonce = crypt.clientNonce }
                cryptSetup = existing
            }
        case .channelState(let channelState):
            state.apply(channelState)
            eventContinuation.yield(.serverStateChanged(state))
        case .channelRemove(let channelRemove):
            state.apply(channelRemove)
            eventContinuation.yield(.serverStateChanged(state))
        case .userState(let userState):
            state.apply(userState)
            eventContinuation.yield(.serverStateChanged(state))
        case .userRemove(let userRemove):
            state.apply(userRemove)
            eventContinuation.yield(.serverStateChanged(state))
        case .serverSync(let sync):
            let info = MumbleServerSyncInfo(
                sessionID: sync.session,
                maxBandwidth: sync.maxBandwidth,
                welcomeText: sync.welcomeText
            )
            syncInfo = info
            finishHandshakeIfPending(with: .success(info))
        case .reject(let reject):
            finishHandshakeIfPending(
                with: .failure(
                    MumbleSessionError.rejected(type: reject.type, reason: reject.reason)))
        case .textMessage(let text):
            eventContinuation.yield(.textMessage(text))
        case .permissionDenied(let denied):
            eventContinuation.yield(.permissionDenied(denied))
        case .ping:
            break  // RTT/crypt stats tracking arrives with the voice channel.
        default:
            break
        }
    }

    /// Suspends until ServerSync arrives. Handles the race where the server
    /// synced before this is called by checking `syncInfo` first.
    private func awaitServerSync() async throws -> MumbleServerSyncInfo {
        if let buffered = bufferedHandshakeResult {
            bufferedHandshakeResult = nil
            return try buffered.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            syncContinuation = continuation
        }
    }

    private func handshakeTimedOut() {
        finishHandshakeIfPending(with: .failure(MumbleSessionError.timeout))
    }

    private func finishHandshakeIfPending(with result: Result<MumbleServerSyncInfo, Error>) {
        if let continuation = syncContinuation {
            syncContinuation = nil
            continuation.resume(with: result)
        } else if bufferedHandshakeResult == nil, syncInfo == nil || isSuccess(result) {
            bufferedHandshakeResult = result
        }
    }

    private func isSuccess(_ result: Result<MumbleServerSyncInfo, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private func startPingLoop() {
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: configuration.pingInterval)
                guard !Task.isCancelled else { return }
                var ping = MumbleProto_Ping()
                ping.timestamp = UInt64(Date().timeIntervalSince1970)
                try? await self.send(.ping(ping))
            }
        }
    }

    private func teardown(error: Error?) async {
        guard isConnected || syncContinuation != nil else { return }
        isConnected = false
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        finishHandshakeIfPending(
            with: .failure(error ?? MumbleSessionError.connectionClosedDuringHandshake))
        await transport.close()
        eventContinuation.finish()
    }
}
