import Darwin
import Foundation

public struct ACPTransportConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]
    public let maximumFrameBytes: Int
    public let maximumPendingOutgoingFrames: Int
    public let maximumPendingOutgoingBytes: Int
    public let standardInputWriteTimeout: Duration
    public let responseTimeout: Duration
    public let promptResponseTimeout: Duration

    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL,
        environment: [String: String]? = nil,
        maximumFrameBytes: Int = 16 * 1_024 * 1_024,
        maximumPendingOutgoingFrames: Int = 64,
        maximumPendingOutgoingBytes: Int = 32 * 1_024 * 1_024,
        standardInputWriteTimeout: Duration = .seconds(5),
        responseTimeout: Duration = .seconds(60),
        promptResponseTimeout: Duration = .seconds(600)
    ) {
        precondition(maximumFrameBytes > 0)
        precondition(maximumPendingOutgoingFrames > 0)
        precondition(maximumPendingOutgoingBytes > 0)
        precondition(standardInputWriteTimeout > .zero)
        precondition(responseTimeout > .zero)
        precondition(promptResponseTimeout > .zero)
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment ?? ACPProcessEnvironment.sanitized()
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumPendingOutgoingFrames = maximumPendingOutgoingFrames
        self.maximumPendingOutgoingBytes = maximumPendingOutgoingBytes
        self.standardInputWriteTimeout = standardInputWriteTimeout
        self.responseTimeout = responseTimeout
        self.promptResponseTimeout = promptResponseTimeout
    }
}

public enum ACPTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyStarted
    case notStarted
    case stopped
    case launchFailed(String)
    case writeFailed(String)
    case outgoingFrameTooLarge(maximumBytes: Int)
    case outgoingQueueFull(maximumFrames: Int, maximumBytes: Int)
    case writeTimedOut
    case responseTimedOut(method: String)
    case protocolViolation(String)
    case unsupportedProtocolVersion(expected: Int, reported: Int)
    case responseError(JSONRPCErrorObject)
    case invalidResponse(method: String)
    case endOfFile
    case processExited(Int32)
    case postResponseHistory(kind: String)
    case cancellationForced
    case cleanupFailed(Set<ProcessIdentity>)

    public var description: String {
        switch self {
        case .alreadyStarted: "ACP transport has already started"
        case .notStarted: "ACP transport has not started"
        case .stopped: "ACP transport is stopped"
        case let .launchFailed(reason): "Could not launch ACP process: \(reason)"
        case let .writeFailed(reason): "Could not write ACP frame: \(reason)"
        case let .outgoingFrameTooLarge(maximumBytes):
            "ACP outgoing frame exceeded \(maximumBytes) bytes"
        case let .outgoingQueueFull(maximumFrames, maximumBytes):
            "ACP outgoing queue exceeded \(maximumFrames) frames or \(maximumBytes) bytes"
        case .writeTimedOut: "Timed out writing an ACP frame"
        case let .responseTimedOut(method): "Timed out waiting for ACP response to \(method)"
        case let .protocolViolation(reason): "ACP protocol violation: \(reason)"
        case let .unsupportedProtocolVersion(expected, reported):
            "Unsupported ACP protocol: expected \(expected), reported \(reported)"
        case let .responseError(error): error.description
        case let .invalidResponse(method): "Malformed response to \(method)"
        case .endOfFile: "ACP process closed stdout"
        case let .processExited(status): "ACP process exited with status \(status)"
        case let .postResponseHistory(kind): "History update \(kind) arrived after session/load response"
        case .cancellationForced: "Cancellation required forced runtime cleanup"
        case let .cleanupFailed(survivors): "ACP process cleanup left \(survivors.count) verified survivor(s)"
        }
    }
}

public struct ACPImplementation: Equatable, Sendable {
    public let name: String
    public let title: String?
    public let version: String
}

public struct ACPInitializeResult: Equatable, Sendable {
    public let protocolVersion: Int
    public let agentInfo: ACPImplementation?
    public let agentCapabilities: JSONValue
    public let authenticationMethods: [JSONValue]
    public let metadata: JSONValue?
    public let raw: JSONValue
}

public struct NewSessionResult: Equatable, Sendable {
    public let sessionID: String
    public let configurationOptions: [JSONValue]
    public let metadata: JSONValue?
    public let raw: JSONValue
}

public struct LoadSessionResult: Equatable, Sendable {
    public let barrier: ReplayBarrier
    public let configurationOptions: [JSONValue]
    public let metadata: JSONValue?
    public let raw: JSONValue
}

public enum PromptStopReason: Equatable, Hashable, Sendable {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .endTurn: "end_turn"
        case .maxTokens: "max_tokens"
        case .maxTurnRequests: "max_turn_requests"
        case .refusal: "refusal"
        case .cancelled: "cancelled"
        case let .unknown(value): value
        }
    }
}

public struct PromptResult: Equatable, Sendable {
    public let stopReason: PromptStopReason
    public let metadata: JSONValue?
    public let raw: JSONValue
}

public struct IncomingACPRequest: Equatable, Hashable, Sendable {
    public let id: RPCID
    public let method: String
    public let params: JSONValue?
    public let metadata: JSONValue?
}

public struct PermissionOption: Equatable, Hashable, Sendable {
    public let optionID: String
    public let name: String
    public let kind: String
    public let metadata: JSONValue?
}

public struct PermissionRequest: Equatable, Hashable, Sendable {
    public let requestID: RPCID
    public let sessionID: String
    public let toolCallID: String
    public let options: [PermissionOption]
    public let metadata: JSONValue?

    public init?(_ request: IncomingACPRequest) {
        guard
            request.method == "session/request_permission",
            let object = request.params?.objectValue,
            let sessionID = object["sessionId"]?.stringValue,
            !sessionID.isEmpty,
            let tool = object["toolCall"]?.objectValue,
            let toolCallID = tool["toolCallId"]?.stringValue,
            !toolCallID.isEmpty,
            let rawOptions = object["options"]?.arrayValue,
            !rawOptions.isEmpty
        else { return nil }

        var decoded: [PermissionOption] = []
        for rawOption in rawOptions {
            guard
                let option = rawOption.objectValue,
                let optionID = option["optionId"]?.stringValue,
                !optionID.isEmpty,
                let name = option["name"]?.stringValue,
                !name.isEmpty,
                let kind = option["kind"]?.stringValue,
                !kind.isEmpty
            else { return nil }
            decoded.append(.init(optionID: optionID, name: name, kind: kind, metadata: option["_meta"]))
        }
        self.requestID = request.id
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.options = decoded
        self.metadata = object["_meta"]
    }
}

public enum ACPDiagnostic: Equatable, Sendable {
    case ignoredNotification(method: String)
    case ignoredResponse(id: RPCID)
    case unknownSessionUpdate(kind: String, sequence: UInt64)
    case standardInput(bytes: Int)
    case standardOutput(bytes: Int)
    case standardError(bytes: Int)
    case failure(ACPTransportError)
}

private struct ResponseFrame: Sendable {
    let result: JSONValue
    let highestYieldedSequence: UInt64
}

private struct PendingRequest {
    let method: String
    let continuation: CheckedContinuation<ResponseFrame, any Error>
    let writeID: UUID
    var deadlineTask: Task<Void, Never>?
}

private enum CancellationPhase: Equatable {
    case none
    case snapshotting(sessionID: String)
    case sent(sessionID: String)
}

/// Owns exactly one ACP process generation and all of its protocol continuations.
public actor ACPTransport {
    private static let cancelledPermissionResult: JSONValue = .object([
        "outcome": .object(["outcome": .string("cancelled")]),
    ])

    public let configuration: ACPTransportConfiguration

    private let updateStream: AsyncStream<EventEnvelope<SessionUpdate>>
    private let updateContinuation: AsyncStream<EventEnvelope<SessionUpdate>>.Continuation
    private let requestStream: AsyncStream<IncomingACPRequest>
    private let requestContinuation: AsyncStream<IncomingACPRequest>.Continuation
    private let diagnosticStream: AsyncStream<ACPDiagnostic>
    private let diagnosticContinuation: AsyncStream<ACPDiagnostic>.Continuation

    private var process: SpawnedProcess?
    private var terminator: ProcessTreeTerminator?
    private var receiveTask: Task<Void, Never>?
    private var standardErrorTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var writerEventTask: Task<Void, Never>?
    private var standardInputWriter: ACPStandardInputWriter?
    private var inputBuffer = Data()
    private var nextRequestID: Int64 = 1
    private var pendingResponses: [RPCID: PendingRequest] = [:]
    private var unresolvedIncoming: [RPCID: IncomingACPRequest] = [:]
    private var sequence: UInt64 = 0
    private var generation: UUID?
    private var deliveryPhase: DeliveryPhase = .live
    private var loadAttemptID: UUID?
    private var activePromptSessionID: String?
    private var cancellationPhase: CancellationPhase = .none
    private var cancellationPromptResponseReceived = false
    private var cleanupInProgress = false
    private var stopping = false
    private var terminalFailure: ACPTransportError?

    public init(configuration: ACPTransportConfiguration) {
        self.configuration = configuration
        (updateStream, updateContinuation) = AsyncStream.makeStream(
            of: EventEnvelope<SessionUpdate>.self,
            bufferingPolicy: .unbounded
        )
        (requestStream, requestContinuation) = AsyncStream.makeStream(
            of: IncomingACPRequest.self,
            bufferingPolicy: .unbounded
        )
        (diagnosticStream, diagnosticContinuation) = AsyncStream.makeStream(
            of: ACPDiagnostic.self,
            bufferingPolicy: .unbounded
        )
    }

    public func updates() -> AsyncStream<EventEnvelope<SessionUpdate>> { updateStream }
    public func incomingRequests() -> AsyncStream<IncomingACPRequest> { requestStream }
    public func diagnostics() -> AsyncStream<ACPDiagnostic> { diagnosticStream }
    public func currentGeneration() -> UUID? { generation }
    public func failure() -> ACPTransportError? { terminalFailure }
    public func rootProcessIdentity() -> ProcessIdentity? { process?.identity }

    @discardableResult
    public func start() throws -> UUID {
        guard process == nil, generation == nil else { throw ACPTransportError.alreadyStarted }
        guard !stopping else { throw ACPTransportError.stopped }
        let spawned: SpawnedProcess
        do {
            spawned = try DirectProcessSpawner.spawn(
                executableURL: configuration.executableURL,
                arguments: configuration.arguments,
                environment: configuration.environment,
                workingDirectory: configuration.workingDirectory
            )
        } catch {
            throw ACPTransportError.launchFailed(String(describing: error))
        }

        let writer: ACPStandardInputWriter
        do {
            writer = try ACPStandardInputWriter(
                fileDescriptor: spawned.standardInput.fileDescriptor,
                maximumFrameBytes: configuration.maximumFrameBytes,
                maximumPendingFrames: configuration.maximumPendingOutgoingFrames,
                maximumPendingBytes: configuration.maximumPendingOutgoingBytes
            )
        } catch {
            abortSpawnedProcess(spawned)
            throw ACPTransportError.launchFailed(String(describing: error))
        }

        let newGeneration = UUID()
        process = spawned
        standardInputWriter = writer
        generation = newGeneration
        terminator = ProcessTreeTerminator(root: spawned.identity)
        startWriterEvents(writer)
        startReaders(for: spawned)
        return newGeneration
    }

    public func initialize(
        clientName: String = "LeChaton",
        clientVersion: String = "0.1.0",
        clientCapabilities: JSONValue = .object([
            "fs": .object([
                "readTextFile": .bool(false),
                "writeTextFile": .bool(false),
            ]),
            "terminal": .bool(false),
            "session": .object([
                "configOptions": .object([:]),
            ]),
            "plan": .object([:]),
            "auth": .object([
                "terminal": .bool(false),
            ]),
            "_meta": .object(["browser-auth-delegated": .bool(true)]),
        ])
    ) async throws -> ACPInitializeResult {
        let result = try await request(
            method: "initialize",
            params: .object([
                "protocolVersion": .integer(Int64(ACPProtocol.supportedVersion)),
                "clientCapabilities": clientCapabilities,
                "clientInfo": .object([
                    "name": .string(clientName),
                    "title": .string("LeChaton"),
                    "version": .string(clientVersion),
                ]),
            ])
        )
        guard
            let object = result.objectValue,
            let rawProtocol = object["protocolVersion"]?.intValue,
            let protocolVersion = Int(exactly: rawProtocol)
        else { throw ACPTransportError.invalidResponse(method: "initialize") }
        guard protocolVersion == ACPProtocol.supportedVersion else {
            throw ACPTransportError.unsupportedProtocolVersion(
                expected: ACPProtocol.supportedVersion,
                reported: protocolVersion
            )
        }

        var implementation: ACPImplementation?
        if let rawInfo = object["agentInfo"] {
            guard
                let info = rawInfo.objectValue,
                let name = info["name"]?.stringValue,
                let version = info["version"]?.stringValue
            else { throw ACPTransportError.invalidResponse(method: "initialize") }
            implementation = ACPImplementation(name: name, title: info["title"]?.stringValue, version: version)
        }

        let capabilities: JSONValue
        switch object["agentCapabilities"] {
        case nil, .some(.null): capabilities = .object([:])
        case let .some(value) where value.objectValue != nil: capabilities = value
        default: throw ACPTransportError.invalidResponse(method: "initialize")
        }
        let authMethods = try decodeOptionalArray(
            object["authMethods"],
            method: "initialize"
        )
        return ACPInitializeResult(
            protocolVersion: protocolVersion,
            agentInfo: implementation,
            agentCapabilities: capabilities,
            authenticationMethods: authMethods,
            metadata: object["_meta"],
            raw: result
        )
    }

    public func newSession(cwd: URL) async throws -> NewSessionResult {
        let result = try await request(
            method: "session/new",
            params: .object([
                "cwd": .string(cwd.path),
                "mcpServers": .array([]),
            ])
        )
        guard
            let object = result.objectValue,
            let sessionID = object["sessionId"]?.stringValue,
            !sessionID.isEmpty
        else { throw ACPTransportError.invalidResponse(method: "session/new") }
        let configurationOptions = try decodeOptionalArray(
            object["configOptions"],
            method: "session/new"
        )
        return NewSessionResult(
            sessionID: sessionID,
            configurationOptions: configurationOptions,
            metadata: object["_meta"],
            raw: result
        )
    }

    public func loadSession(sessionID: String, cwd: URL) async throws -> LoadSessionResult {
        guard deliveryPhase == .live, loadAttemptID == nil else {
            throw ACPTransportError.protocolViolation("A session/load attempt is already active")
        }
        guard let generation else { throw ACPTransportError.notStarted }
        let attemptID = UUID()
        loadAttemptID = attemptID
        deliveryPhase = .loadPending

        do {
            let frame = try await requestFrame(
                method: "session/load",
                params: .object([
                    "sessionId": .string(sessionID),
                    "cwd": .string(cwd.path),
                    "mcpServers": .array([]),
                ])
            )
            guard let object = frame.result.objectValue else {
                throw ACPTransportError.invalidResponse(method: "session/load")
            }
            let configurationOptions = try decodeOptionalArray(
                object["configOptions"],
                method: "session/load"
            )
            if let modes = object["modes"], modes != .null, modes.objectValue == nil {
                throw ACPTransportError.invalidResponse(method: "session/load")
            }
            deliveryPhase = .postLoadGuard
            return LoadSessionResult(
                barrier: ReplayBarrier(
                    runtimeGeneration: generation,
                    loadAttemptID: attemptID,
                    throughSequence: frame.highestYieldedSequence
                ),
                configurationOptions: configurationOptions,
                metadata: object["_meta"],
                raw: frame.result
            )
        } catch {
            failTransport(error as? ACPTransportError ?? .protocolViolation(String(describing: error)))
            throw error
        }
    }

    public func prompt(sessionID: String, text: String) async throws -> PromptResult {
        guard activePromptSessionID == nil, cancellationPhase == .none else {
            throw ACPTransportError.protocolViolation("Only one prompt may be active")
        }
        // This actor-isolated transition closes the post-load guard before the request is written.
        deliveryPhase = .live
        loadAttemptID = nil
        activePromptSessionID = sessionID
        cancellationPromptResponseReceived = false
        defer {
            activePromptSessionID = nil
            if cancellationPhase == .none {
                cancellationPromptResponseReceived = false
            }
        }

        let result = try await request(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
            responseTimeout: configuration.promptResponseTimeout
        )
        guard
            let object = result.objectValue,
            let stopReason = object["stopReason"]?.stringValue
        else { throw ACPTransportError.invalidResponse(method: "session/prompt") }
        return PromptResult(
            stopReason: PromptStopReason(rawValue: stopReason),
            metadata: object["_meta"],
            raw: result
        )
    }

    /// Performs the complete cancellation contract. A verified process-tree snapshot is taken
    /// immediately before the one wire notification, unresolved and later permissions are
    /// cancelled once, and the runtime is retained only after the prompt response and all
    /// verified descendants have both completed. Any timeout forces complete runtime cleanup.
    @discardableResult
    public func cancelPrompt(
        sessionID: String,
        gracefulPeriod: Duration = .seconds(5),
        terminationGracePeriod: Duration = .seconds(2),
        rescanInterval: Duration = .milliseconds(25),
        killConfirmationPeriod: Duration = .milliseconds(250)
    ) async throws -> Bool {
        guard activePromptSessionID == sessionID else { return false }
        guard cancellationPhase == .none else { return false }
        guard let terminator else { throw ACPTransportError.notStarted }

        // Mark the boundary before awaiting the process-table scan so a concurrent duplicate
        // cannot send another cancellation and permission decisions cannot win the race.
        cancellationPhase = .snapshotting(sessionID: sessionID)
        cancellationPromptResponseReceived = false
        _ = await terminator.refresh()

        guard !stopping, terminalFailure == nil else {
            cancellationPhase = .none
            throw terminalFailure ?? ACPTransportError.stopped
        }

        cancellationPhase = .sent(sessionID: sessionID)
        do {
            // Queue acceptance is synchronous and nonblocking, so no actor suspension occurs
            // between the verified snapshot and the one ordered cancellation notification.
            _ = try enqueueFrame(JSONRPCMessage.notification(
                method: "session/cancel",
                params: .object(["sessionId": .string(sessionID)])
            ))

            let permissionIDs = unresolvedIncoming.values
                .filter { $0.method == "session/request_permission" }
                .map(\.id)
            for id in permissionIDs {
                try enqueueCancellationResponse(id: id)
            }
        } catch {
            let failure = error as? ACPTransportError ?? .writeFailed(String(describing: error))
            failTransport(failure)
            throw failure
        }

        let deadline = ContinuousClock.now.advanced(by: gracefulPeriod)
        while ContinuousClock.now < deadline {
            let descendants = await terminator.liveDescendantIdentities()
            let rootIsAlive = await terminator.rootIsAlive()
            if
                cancellationPromptResponseReceived,
                descendants.isEmpty,
                rootIsAlive,
                terminalFailure == nil
            {
                cancellationPhase = .none
                cancellationPromptResponseReceived = false
                return true
            }
            if terminalFailure != nil || !rootIsAlive || Task.isCancelled { break }
            try? await Task.sleep(for: rescanInterval)
        }

        cleanupInProgress = true
        let report = await terminator.terminate(
            gracePeriod: terminationGracePeriod,
            rescanInterval: rescanInterval,
            killConfirmationPeriod: killConfirmationPeriod
        )
        let cancellationFailure: ACPTransportError = report.survivors.isEmpty
            ? .cancellationForced
            : .cleanupFailed(report.survivors)
        let failure = terminalFailure ?? cancellationFailure
        failTransport(cancellationFailure)
        cleanupInProgress = false
        cancellationPhase = .none
        cancellationPromptResponseReceived = false
        throw failure
    }

    public func respond(id: RPCID, result: JSONValue) throws {
        try respondOnce(
            id: id,
            result: cancellationPhase == .none ? result : Self.cancelledPermissionResult
        )
    }

    private func respondOnce(id: RPCID, result: JSONValue) throws {
        guard unresolvedIncoming[id] != nil else { return }

        // Queue admission is the exactly-once commit edge. Keeping the request
        // unresolved until this synchronous operation succeeds makes a bounded
        // admission failure retryable without allowing cancellation or another
        // decision to enqueue a second response for the same JSON-RPC ID.
        _ = try enqueueFrame(JSONRPCMessage.response(id: id, result: result))
        unresolvedIncoming.removeValue(forKey: id)
    }

    public func respondToPermission(id: RPCID, selectedOptionID: String) throws {
        try respond(id: id, result: .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(selectedOptionID),
            ]),
        ]))
    }

    public func respondToPermissionCancellation(id: RPCID) throws {
        try respondOnce(id: id, result: Self.cancelledPermissionResult)
    }

    private func enqueueCancellationResponse(id: RPCID) throws {
        try respondOnce(id: id, result: Self.cancelledPermissionResult)
    }

    public func request(
        method: String,
        params: JSONValue? = nil,
        responseTimeout: Duration? = nil
    ) async throws -> JSONValue {
        try await requestFrame(
            method: method,
            params: params,
            responseTimeout: responseTimeout
        ).result
    }

    public func sendNotification(method: String, params: JSONValue? = nil) async throws {
        try await writeFrame(JSONRPCMessage.notification(method: method, params: params))
    }

    /// Starts/refreshes descendant tracking at the cancellation boundary.
    public func snapshotProcessTree() async -> Set<ProcessIdentity> {
        guard let terminator else { return [] }
        return await terminator.refresh()
    }

    public func liveProcessTree() async -> Set<ProcessIdentity> {
        guard let terminator else { return [] }
        return await terminator.liveIdentities()
    }

    public func forceCleanup(gracePeriod: Duration = .seconds(2)) async throws -> ProcessCleanupReport {
        guard let terminator else {
            return .init(signalled: [], forceKilled: [], survivors: [])
        }
        cleanupInProgress = true
        let report = await terminator.terminate(gracePeriod: gracePeriod)
        if !report.survivors.isEmpty {
            let failure = ACPTransportError.cleanupFailed(report.survivors)
            failTransport(failure)
            cleanupInProgress = false
            throw failure
        }
        failTransport(.cancellationForced)
        cleanupInProgress = false
        return report
    }

    @discardableResult
    public func stop(gracePeriod: Duration = .seconds(2)) async -> ProcessCleanupReport? {
        guard !stopping else { return nil }
        stopping = true
        cancellationPhase = .none
        let writer = standardInputWriter
        writer?.initiateStop()
        failPending(with: .stopped)
        unresolvedIncoming.removeAll()
        if let writer { await writer.waitUntilStopped() }
        try? process?.standardInput.close()

        cleanupInProgress = true
        let report = await terminator?.terminate(gracePeriod: gracePeriod)
        cleanupInProgress = false
        receiveTask?.cancel()
        standardErrorTask?.cancel()
        waitTask?.cancel()
        writerEventTask?.cancel()
        try? process?.standardOutput.close()
        try? process?.standardError.close()
        finishStreams()
        process = nil
        standardInputWriter = nil
        return report
    }

    private func requestFrame(
        method: String,
        params: JSONValue?,
        responseTimeout: Duration? = nil
    ) async throws -> ResponseFrame {
        guard process != nil, generation != nil else { throw ACPTransportError.notStarted }
        if let terminalFailure { throw terminalFailure }
        guard !stopping else { throw ACPTransportError.stopped }

        let id = RPCID.integer(nextRequestID)
        nextRequestID += 1
        let timeout = responseTimeout ?? configuration.responseTimeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    let writeID = try enqueueFrame(
                        JSONRPCMessage.request(id: id, method: method, params: params)
                    )
                    let deadlineTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        await self?.requestDeadlineExpired(id)
                    }
                    pendingResponses[id] = PendingRequest(
                        method: method,
                        continuation: continuation,
                        writeID: writeID,
                        deadlineTask: deadlineTask
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(id) }
        }
    }

    private func cancelPendingRequest(_ id: RPCID) {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        pending.deadlineTask?.cancel()
        standardInputWriter?.cancel(id: pending.writeID)
        pending.continuation.resume(throwing: CancellationError())
    }

    private func requestDeadlineExpired(_ id: RPCID) {
        guard let pending = pendingResponses[id] else { return }
        failTransport(.responseTimedOut(method: pending.method))
    }

    private func startWriterEvents(_ writer: ACPStandardInputWriter) {
        let events = writer.events()
        writerEventTask = Task.detached { [weak self] in
            for await event in events {
                await self?.receivedWriterEvent(event)
            }
        }
    }

    private func receivedWriterEvent(_ event: ACPStandardInputWriterEvent) {
        switch event {
        case let .wrote(bytes):
            diagnosticContinuation.yield(.standardInput(bytes: bytes))
        case let .failed(error):
            failTransport(error)
        }
    }

    private func startReaders(for spawned: SpawnedProcess) {
        let stdoutDescriptor = spawned.standardOutput.fileDescriptor
        receiveTask = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let chunk = try readPipeChunk(
                        fileDescriptor: stdoutDescriptor,
                        maximumBytes: 64 * 1_024
                    ) else {
                        await self?.receivedEOF()
                        return
                    }
                    await self?.ingest(chunk)
                }
            } catch {
                await self?.readerFailed(error)
            }
        }

        let stderrDescriptor = spawned.standardError.fileDescriptor
        standardErrorTask = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let chunk = try readPipeChunk(
                        fileDescriptor: stderrDescriptor,
                        maximumBytes: 16 * 1_024
                    ) else { return }
                    await self?.receivedStandardError(byteCount: chunk.count)
                }
            } catch {
                // stderr is diagnostic-only; stdout/process exit remains authoritative.
            }
        }

        let pid = spawned.identity.pid
        waitTask = Task.detached { [weak self] in
            var status: Int32 = 0
            var result: pid_t = -1
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            if result == pid { await self?.childExited(status: status) }
        }
    }

    private func ingest(_ chunk: Data) {
        guard terminalFailure == nil, !stopping else { return }
        diagnosticContinuation.yield(.standardOutput(bytes: chunk.count))
        inputBuffer.append(chunk)
        guard inputBuffer.count <= configuration.maximumFrameBytes || inputBuffer.contains(0x0A) else {
            failTransport(.protocolViolation("ACP frame exceeded \(configuration.maximumFrameBytes) bytes"))
            return
        }

        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            var line = inputBuffer[..<newline]
            inputBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            guard line.count <= configuration.maximumFrameBytes else {
                failTransport(.protocolViolation("ACP frame exceeded \(configuration.maximumFrameBytes) bytes"))
                return
            }
            do {
                try route(JSONRPCMessage.decode(line: Data(line)))
            } catch let error as ACPTransportError {
                failTransport(error)
                return
            } catch {
                failTransport(.protocolViolation(String(describing: error)))
                return
            }
        }
    }

    private func route(_ message: JSONRPCMessage) throws {
        switch message {
        case let .response(response):
            guard let pending = pendingResponses.removeValue(forKey: response.id) else {
                diagnosticContinuation.yield(.ignoredResponse(id: response.id))
                return
            }
            pending.deadlineTask?.cancel()
            if pending.method == "session/prompt", cancellationPhase != .none {
                cancellationPromptResponseReceived = true
            }
            // Close the replay window at response decode time. Resuming the continuation first
            // would let later frames from the same stdout read remain incorrectly tagged loading.
            if pending.method == "session/load", deliveryPhase == .loadPending {
                deliveryPhase = .postLoadGuard
            }
            if let error = response.error {
                pending.continuation.resume(throwing: ACPTransportError.responseError(error))
            } else if let result = response.result {
                pending.continuation.resume(returning: .init(
                    result: result,
                    highestYieldedSequence: sequence
                ))
            } else {
                pending.continuation.resume(throwing: ACPTransportError.invalidResponse(method: pending.method))
            }

        case let .notification(notification):
            guard notification.method == "session/update" else {
                diagnosticContinuation.yield(.ignoredNotification(method: notification.method))
                return
            }
            let sessionNotification = try SessionNotification.decode(params: notification.params)
            sequence += 1
            if deliveryPhase == .postLoadGuard, sessionNotification.update.isReducerBoundHistory {
                throw ACPTransportError.postResponseHistory(kind: sessionNotification.update.kind)
            }
            guard let generation else { throw ACPTransportError.notStarted }
            let envelope = EventEnvelope(
                runtimeGeneration: generation,
                loadAttemptID: loadAttemptID,
                sequence: sequence,
                deliveryPhase: deliveryPhase,
                payload: sessionNotification.update
            )
            updateContinuation.yield(envelope)
            if case let .unknown(kind, _) = sessionNotification.update {
                diagnosticContinuation.yield(.unknownSessionUpdate(kind: kind, sequence: sequence))
            }

        case let .request(request):
            guard request.method == "session/request_permission" else {
                _ = try enqueueFrame(JSONRPCMessage.errorResponse(
                    id: request.id,
                    error: .init(code: -32601, message: "Method not found")
                ))
                return
            }
            let incoming = IncomingACPRequest(
                id: request.id,
                method: request.method,
                params: request.params,
                metadata: request.metadata
            )
            guard PermissionRequest(incoming) != nil else {
                _ = try enqueueFrame(JSONRPCMessage.errorResponse(
                    id: request.id,
                    error: .init(code: -32602, message: "Invalid params")
                ))
                return
            }
            unresolvedIncoming[request.id] = incoming
            if cancellationPhase != .none {
                if case .sent = cancellationPhase {
                    try enqueueCancellationResponse(id: request.id)
                }
                return
            }
            requestContinuation.yield(incoming)
        }
    }

    @discardableResult
    private func enqueueFrame(_ value: JSONValue) throws -> UUID {
        guard process != nil, let writer = standardInputWriter else {
            throw ACPTransportError.notStarted
        }
        if let terminalFailure { throw terminalFailure }
        guard !stopping else { throw ACPTransportError.stopped }
        return try writer.enqueue(
            encodedFrame(value),
            timeout: configuration.standardInputWriteTimeout
        )
    }

    private func writeFrame(_ value: JSONValue) async throws {
        guard process != nil, let writer = standardInputWriter else {
            throw ACPTransportError.notStarted
        }
        if let terminalFailure { throw terminalFailure }
        guard !stopping else { throw ACPTransportError.stopped }
        do {
            try await writer.write(
                encodedFrame(value),
                timeout: configuration.standardInputWriteTimeout
            )
        } catch let error as ACPTransportError {
            switch error {
            case .writeFailed, .writeTimedOut:
                failTransport(error)
            default:
                break
            }
            throw error
        } catch {
            throw error
        }
    }

    private func encodedFrame(_ value: JSONValue) throws -> Data {
        var data: Data
        do {
            data = try value.encodedData()
        } catch {
            throw ACPTransportError.writeFailed(String(describing: error))
        }
        data.append(0x0A)
        return data
    }

    private func receivedStandardError(byteCount: Int) {
        diagnosticContinuation.yield(.standardError(bytes: byteCount))
    }

    private func readerFailed(_ error: any Error) {
        guard !stopping else { return }
        failTransport(.protocolViolation("stdout read failed: \(error)"))
    }

    private func receivedEOF() {
        guard !stopping else { return }
        if !inputBuffer.isEmpty {
            failTransport(.protocolViolation("EOF in partial JSON-RPC frame"))
        } else {
            failTransport(.endOfFile)
        }
    }

    private func childExited(status: Int32) {
        guard !stopping, terminalFailure == nil else { return }
        failTransport(.processExited(status))
    }

    private func failTransport(_ failure: ACPTransportError) {
        guard terminalFailure == nil, !stopping else { return }
        terminalFailure = failure
        loadAttemptID = nil
        cancellationPhase = .none
        cancellationPromptResponseReceived = false
        let writer = standardInputWriter
        writer?.initiateStop()
        failPending(with: failure)
        unresolvedIncoming.removeAll()
        diagnosticContinuation.yield(.failure(failure))
        updateContinuation.finish()
        requestContinuation.finish()
        let standardInput = process?.standardInput
        let terminator = cleanupInProgress ? nil : terminator
        Task {
            if let writer { await writer.waitUntilStopped() }
            try? standardInput?.close()
            if let terminator { _ = await terminator.terminate() }
        }
    }

    private func failPending(with error: ACPTransportError) {
        let pending = pendingResponses.values
        pendingResponses.removeAll()
        for request in pending {
            request.deadlineTask?.cancel()
            standardInputWriter?.cancel(id: request.writeID)
            request.continuation.resume(throwing: error)
        }
    }

    private func finishStreams() {
        updateContinuation.finish()
        requestContinuation.finish()
        diagnosticContinuation.finish()
    }
}

enum ACPStandardInputWriterEvent: Sendable {
    case wrote(bytes: Int)
    case failed(ACPTransportError)
}

private struct FrameWriteWasCancelled: Error, Sendable {
    let wroteBytes: Int
}

/// A dedicated serial writer keeps POSIX backpressure off the transport actor.
/// Enqueueing is synchronous and bounded, so cancellation can atomically queue
/// its notification after the process-tree snapshot while actual writes happen
/// on a detached worker against a nonblocking descriptor.
final class ACPStandardInputWriter: @unchecked Sendable {
    private struct Frame {
        let id: UUID
        let data: Data
        let timeout: Duration
        let completion: CheckedContinuation<Void, any Error>?
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    private let fileDescriptor: Int32
    private let maximumFrameBytes: Int
    private let maximumPendingFrames: Int
    private let maximumPendingBytes: Int
    private let writeOperation: @Sendable (Data, Int32, Duration) throws -> Int
    private let eventStream: AsyncStream<ACPStandardInputWriterEvent>
    private let eventContinuation: AsyncStream<ACPStandardInputWriterEvent>.Continuation
    private let lock = NSLock()

    private var queue: [Frame] = []
    private var active: Frame?
    private var activeTask: Task<Void, Never>?
    private var outstandingBytes = 0
    private var stopped = false

    init(
        fileDescriptor: Int32,
        maximumFrameBytes: Int,
        maximumPendingFrames: Int,
        maximumPendingBytes: Int,
        writeOperation: @escaping @Sendable (Data, Int32, Duration) throws -> Int = {
            try writeNonblockingFrame($0, fileDescriptor: $1, timeout: $2)
        }
    ) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw ACPTransportError.writeFailed(String(cString: strerror(errno)))
        }
        // Prevent a closed child pipe from terminating LeChaton with SIGPIPE.
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)

        self.fileDescriptor = fileDescriptor
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumPendingFrames = maximumPendingFrames
        self.maximumPendingBytes = maximumPendingBytes
        self.writeOperation = writeOperation
        (eventStream, eventContinuation) = AsyncStream.makeStream(
            of: ACPStandardInputWriterEvent.self,
            bufferingPolicy: .unbounded
        )
    }

    func events() -> AsyncStream<ACPStandardInputWriterEvent> { eventStream }

    @discardableResult
    func enqueue(_ data: Data, timeout: Duration) throws -> UUID {
        let id = UUID()
        try enqueue(
            Frame(id: id, data: data, timeout: timeout, completion: nil),
            cancellationFlag: nil
        )
        return id
    }

    func write(_ data: Data, timeout: Duration) async throws {
        let id = UUID()
        let flag = CancellationFlag()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try enqueue(
                        Frame(id: id, data: data, timeout: timeout, completion: continuation),
                        cancellationFlag: flag
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            flag.cancel()
            self.cancel(id: id)
        }
    }

    func cancel(id: UUID) {
        var continuation: CheckedContinuation<Void, any Error>?
        lock.lock()
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let frame = queue.remove(at: index)
            outstandingBytes -= frame.data.count
            continuation = frame.completion
            startNextIfNeededLocked()
        } else if active?.id == id {
            activeTask?.cancel()
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    /// Synchronously prevents further admission and cancels the active worker.
    /// Call `waitUntilStopped()` before closing the owned descriptor.
    func initiateStop() {
        var continuations: [CheckedContinuation<Void, any Error>] = []
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        activeTask?.cancel()
        if let completion = active?.completion { continuations.append(completion) }
        continuations.append(contentsOf: queue.compactMap(\.completion))
        active = nil
        queue.removeAll()
        outstandingBytes = 0
        lock.unlock()

        for continuation in continuations {
            continuation.resume(throwing: ACPTransportError.stopped)
        }
        eventContinuation.finish()
    }

    /// Joins the detached worker so its final descriptor access happens before
    /// the transport closes (and the OS can reuse) that descriptor.
    func waitUntilStopped() async {
        let task = activeTaskSnapshot()
        await task?.value
        clearCompletedActiveTask()
    }

    func stop() async {
        initiateStop()
        await waitUntilStopped()
    }

    private func enqueue(_ frame: Frame, cancellationFlag: CancellationFlag?) throws {
        guard frame.data.count <= maximumFrameBytes else {
            throw ACPTransportError.outgoingFrameTooLarge(maximumBytes: maximumFrameBytes)
        }

        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw ACPTransportError.stopped }
        if cancellationFlag?.isCancelled == true { throw CancellationError() }
        let outstandingFrames = queue.count + (active == nil ? 0 : 1)
        guard
            frame.data.count <= maximumPendingBytes,
            outstandingFrames < maximumPendingFrames,
            outstandingBytes <= maximumPendingBytes - frame.data.count
        else {
            throw ACPTransportError.outgoingQueueFull(
                maximumFrames: maximumPendingFrames,
                maximumBytes: maximumPendingBytes
            )
        }
        queue.append(frame)
        outstandingBytes += frame.data.count
        startNextIfNeededLocked()
    }

    private func startNextIfNeededLocked() {
        guard !stopped, active == nil, !queue.isEmpty else { return }
        let frame = queue.removeFirst()
        active = frame
        let descriptor = fileDescriptor
        let writeOperation = writeOperation
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Int, any Error>
            do {
                result = .success(try writeOperation(frame.data, descriptor, frame.timeout))
            } catch {
                result = .failure(error)
            }
            self?.finished(id: frame.id, result: result)
        }
        activeTask = task
    }

    private func activeTaskSnapshot() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return activeTask
    }

    private func clearCompletedActiveTask() {
        lock.lock()
        activeTask = nil
        lock.unlock()
    }

    private func finished(id: UUID, result: Result<Int, any Error>) {
        var successfulBytes: Int?
        var completions: [(CheckedContinuation<Void, any Error>, Result<Void, any Error>)] = []
        var terminalFailure: ACPTransportError?

        lock.lock()
        guard !stopped, let frame = active, frame.id == id else {
            lock.unlock()
            return
        }
        active = nil
        activeTask = nil
        outstandingBytes -= frame.data.count

        switch result {
        case let .success(bytes):
            successfulBytes = bytes
            if let completion = frame.completion { completions.append((completion, .success(()))) }
            startNextIfNeededLocked()

        case let .failure(error):
            if let cancellation = error as? FrameWriteWasCancelled, cancellation.wroteBytes == 0 {
                if let completion = frame.completion {
                    completions.append((completion, .failure(CancellationError())))
                }
                startNextIfNeededLocked()
            } else {
                let failure: ACPTransportError
                if let transportError = error as? ACPTransportError {
                    failure = transportError
                } else if let cancellation = error as? FrameWriteWasCancelled {
                    failure = .writeFailed(
                        "Outgoing frame was cancelled after \(cancellation.wroteBytes) bytes"
                    )
                } else {
                    failure = .writeFailed(String(describing: error))
                }
                stopped = true
                terminalFailure = failure
                if let completion = frame.completion {
                    completions.append((completion, .failure(failure)))
                }
                for queued in queue {
                    if let completion = queued.completion {
                        completions.append((completion, .failure(failure)))
                    }
                }
                queue.removeAll()
                outstandingBytes = 0
            }
        }
        lock.unlock()

        for (continuation, completion) in completions {
            continuation.resume(with: completion)
        }
        if let successfulBytes {
            eventContinuation.yield(.wrote(bytes: successfulBytes))
        }
        if let terminalFailure {
            eventContinuation.yield(.failed(terminalFailure))
            eventContinuation.finish()
        }
    }
}

private func writeNonblockingFrame(
    _ data: Data,
    fileDescriptor: Int32,
    timeout: Duration
) throws -> Int {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    return try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return 0 }
        var written = 0
        while written < rawBuffer.count {
            if Task.isCancelled { throw FrameWriteWasCancelled(wroteBytes: written) }
            if ContinuousClock.now >= deadline { throw ACPTransportError.writeTimedOut }

            let result = Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: written),
                rawBuffer.count - written
            )
            if result > 0 {
                written += result
                continue
            }
            if result == -1, errno == EINTR { continue }
            if result == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let pollResult = Darwin.poll(&descriptor, 1, 25)
                if pollResult == -1, errno == EINTR { continue }
                if pollResult == -1 {
                    throw ACPTransportError.writeFailed(String(cString: strerror(errno)))
                }
                if descriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 {
                    throw ACPTransportError.writeFailed("ACP standard input closed")
                }
                continue
            }
            throw ACPTransportError.writeFailed(String(cString: strerror(errno)))
        }
        return written
    }
}

private func abortSpawnedProcess(_ process: SpawnedProcess) {
    _ = Darwin.kill(process.identity.pid, SIGKILL)
    try? process.standardInput.close()
    try? process.standardOutput.close()
    try? process.standardError.close()
    var status: Int32 = 0
    var result: pid_t = -1
    repeat { result = waitpid(process.identity.pid, &status, 0) } while result == -1 && errno == EINTR
}

private struct PipeReadError: Error, CustomStringConvertible {
    let code: Int32

    var description: String { String(cString: strerror(code)) }
}

/// `FileHandle.read(upToCount:)` may wait for the requested count on a pipe on macOS.
/// A single POSIX read returns as soon as any ACP bytes are available, while preserving
/// the transport's one-reader ordering guarantee.
private func readPipeChunk(fileDescriptor: Int32, maximumBytes: Int) throws -> Data? {
    var storage = [UInt8](repeating: 0, count: maximumBytes)
    while true {
        let count = storage.withUnsafeMutableBytes { buffer in
            Darwin.read(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        if count > 0 {
            return Data(storage.prefix(count))
        }
        if count == 0 { return nil }
        if errno == EINTR { continue }
        throw PipeReadError(code: errno)
    }
}

private func decodeOptionalArray(
    _ value: JSONValue?,
    method: String
) throws -> [JSONValue] {
    switch value {
    case nil, .some(.null):
        []
    case let .some(.array(values)):
        values
    default:
        throw ACPTransportError.invalidResponse(method: method)
    }
}
