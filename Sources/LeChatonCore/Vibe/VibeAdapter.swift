import Foundation

/// Vibe-specific protocol operations live here rather than leaking into ACP transport users.
public struct VibeAdapter: Sendable {
    public static let delegatedAuthenticationMethodID = "browser-auth-delegated"
    static let maximumSessionListPages = 32

    public let locator: VibeLocator

    private let transportFactory: @Sendable (ACPTransportConfiguration) -> ACPTransport

    public init(locator: VibeLocator = VibeLocator()) {
        self.locator = locator
        transportFactory = { ACPTransport(configuration: $0) }
    }

    init(
        locator: VibeLocator = VibeLocator(),
        transportFactory: @escaping @Sendable (ACPTransportConfiguration) -> ACPTransport
    ) {
        self.locator = locator
        self.transportFactory = transportFactory
    }

    public func locate(explicitPath: String? = nil, storedPath: String? = nil) throws -> VibeExecutable {
        try locator.locate(explicitPath: explicitPath, storedPath: storedPath)
    }

    public func validateExecutable(
        _ candidate: URL,
        source: VibeExecutable.Source = .explicit
    ) throws -> VibeExecutable {
        try locator.validate(candidate, source: source)
    }

    /// Initializes an already-owned process and enforces the exact supported Vibe contract.
    public func initializeAndValidate(
        transport: ACPTransport,
        executable: VibeExecutable
    ) async throws -> VibeCompatibility {
        let initialization = try await transport.initialize(
            clientCapabilities: Self.clientCapabilities
        )
        return try VibeCompatibility(executable: executable, initialization: initialization)
    }

    /// Vibe 2.21.0 exposes authentication status through an extension request.
    public func authenticationStatus(
        transport: ACPTransport
    ) async throws -> VibeAuthenticationStatus {
        let raw = try await transport.request(
            method: "_auth/status",
            params: .object([:])
        )
        return VibeAuthenticationStatus(raw: raw)
    }

    /// Uses ACP's persisted-session listing rather than treating `session/new`
    /// as a durability acknowledgement. Vibe may paginate this response.
    public func persistedSessionExists(
        sessionID: String,
        cwd: URL,
        transport: ACPTransport
    ) async throws -> Bool {
        var cursor: String?
        var seenCursors: Set<String> = []
        var pageCount = 0
        let expectedCWD = cwd.standardizedFileURL.path

        while true {
            let page = try await transport.listSessions(cwd: cwd, cursor: cursor)
            pageCount += 1
            if page.sessions.contains(where: { session in
                session.sessionID == sessionID
                    && URL(filePath: session.cwd, directoryHint: .isDirectory)
                        .standardizedFileURL.path == expectedCWD
            }) {
                return true
            }

            guard let nextCursor = page.nextCursor else { return false }
            guard pageCount < Self.maximumSessionListPages else {
                throw VibeAdapterError.sessionListPageLimitExceeded(
                    maximumPages: Self.maximumSessionListPages
                )
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw VibeAdapterError.invalidSessionListPagination(nextCursor)
            }
            cursor = nextCursor
        }
    }

    /// Maps only Vibe 2.21.0's exact missing-session response. Other ACP
    /// failures retain their generic transport identity for defensive handling.
    public func loadSession(
        sessionID: String,
        cwd: URL,
        transport: ACPTransport
    ) async throws -> LoadSessionResult {
        do {
            return try await transport.loadSession(sessionID: sessionID, cwd: cwd)
        } catch let error as ACPTransportError {
            let expected = JSONRPCErrorObject(
                code: -32602,
                message: "Session not found: \(sessionID)",
                data: .object(["session_id": .string(sessionID)])
            )
            guard error == .responseError(expected) else { throw error }
            throw VibeAdapterError.savedSessionUnavailable(sessionID)
        }
    }

    /// Queries Vibe's repository-trust extension without teaching generic ACP about its shape.
    public func repositoryTrustStatus(
        cwd: URL,
        transport: ACPTransport
    ) async throws -> VibeRepositoryTrustStatus {
        let raw = try await transport.request(
            method: "_trust/status",
            params: .object(["cwd": .string(cwd.path)])
        )
        return VibeRepositoryTrustStatus(raw: raw)
    }

    /// Applies one decision advertised by `_trust/status`. Callers remain
    /// responsible for presenting the choice to the user and must not invent a
    /// decision or persist it as LeChaton metadata.
    public func applyRepositoryTrustDecision(
        cwd: URL,
        decision: String,
        transport: ACPTransport
    ) async throws -> VibeRepositoryTrustStatus {
        let raw = try await transport.request(
            method: "_trust/decision",
            params: .object([
                "cwd": .string(cwd.path),
                "decision": .string(decision),
            ])
        )
        return VibeRepositoryTrustStatus(raw: raw)
    }

    /// Starts Vibe's process-bound delegated browser flow.
    public func startDelegatedAuthentication(
        transport: ACPTransport
    ) async throws -> VibeDelegatedAuthenticationAttempt {
        let raw = try await transport.request(
            method: "authenticate",
            params: .object([
                "methodId": .string(Self.delegatedAuthenticationMethodID),
                "_meta": .object(["action": .string("start")]),
            ])
        )
        guard
            let details = raw["_meta"]?[Self.delegatedAuthenticationMethodID]?.objectValue,
            let attemptID = details["attemptId"]?.stringValue,
            !attemptID.isEmpty,
            let rawURL = details["signInUrl"]?.stringValue,
            let signInURL = URL(string: rawURL),
            let scheme = signInURL.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            signInURL.host != nil
        else {
            throw VibeAdapterError.invalidDelegatedAuthenticationStart
        }
        return VibeDelegatedAuthenticationAttempt(
            id: attemptID,
            signInURL: signInURL,
            expiresAt: details["expiresAt"]?.stringValue,
            raw: raw
        )
    }

    /// Completes an attempt on the caller's existing transport. `AuthCoordinator` is responsible
    /// for proving that this is the same process which started the attempt.
    public func completeDelegatedAuthentication(
        attemptID: String,
        transport: ACPTransport
    ) async throws -> VibeDelegatedAuthenticationCompletion {
        guard !attemptID.isEmpty else { throw VibeAdapterError.invalidAuthenticationAttemptID }
        let raw = try await transport.request(
            method: "authenticate",
            params: .object([
                "methodId": .string(Self.delegatedAuthenticationMethodID),
                "_meta": .object([
                    "action": .string("complete"),
                    "attemptId": .string(attemptID),
                ]),
            ])
        )
        guard
            let details = raw["_meta"]?[Self.delegatedAuthenticationMethodID]?.objectValue,
            let reportedAttemptID = details["attemptId"]?.stringValue,
            reportedAttemptID == attemptID
        else {
            throw VibeAdapterError.invalidDelegatedAuthenticationCompletion
        }
        let rawStatus = details["status"]?.stringValue
        return VibeDelegatedAuthenticationCompletion(
            attemptID: reportedAttemptID,
            state: rawStatus == "completed" ? .completed : .unknown(rawStatus),
            persistenceResult: details["persistResult"],
            raw: raw
        )
    }

    /// Sends the ACP configuration write while keeping option-shape knowledge out of generic ACP.
    public func setConfigurationOption(
        sessionID: String,
        optionID: String,
        kind: VibeConfigurationOption.Kind,
        value: JSONValue,
        transport: ACPTransport
    ) async throws -> VibeConfigurationWriteResult {
        guard !sessionID.isEmpty, !optionID.isEmpty else {
            throw VibeAdapterError.invalidConfigurationRequest
        }

        var parameters: [String: JSONValue] = [
            "sessionId": .string(sessionID),
            "configId": .string(optionID),
            "value": value,
        ]
        switch kind {
        case .select:
            guard value.stringValue != nil else { throw VibeAdapterError.invalidConfigurationRequest }
        case .boolean:
            guard value.boolValue != nil else { throw VibeAdapterError.invalidConfigurationRequest }
            parameters["type"] = .string("boolean")
        case .unknown:
            throw VibeAdapterError.unsupportedConfigurationOptionKind(kind.rawValue)
        }

        let raw = try await transport.request(
            method: "session/set_config_option",
            params: .object(parameters)
        )
        guard let object = raw.objectValue else {
            throw VibeAdapterError.invalidConfigurationResponse
        }

        let rawOptions: [JSONValue]
        switch object["configOptions"] {
        case nil, .some(.null):
            // The fresh session/load response is authoritative. Some compatible agents return
            // only an empty acknowledgement for the write itself.
            rawOptions = []
        case let .some(.array(options)):
            rawOptions = options
        default:
            throw VibeAdapterError.invalidConfigurationResponse
        }

        var options: [VibeConfigurationOption] = []
        options.reserveCapacity(rawOptions.count)
        for rawOption in rawOptions {
            guard let option = VibeConfigurationOption(rawOption) else {
                throw VibeAdapterError.invalidConfigurationResponse
            }
            options.append(option)
        }
        return VibeConfigurationWriteResult(
            options: options,
            metadata: object["_meta"],
            raw: raw
        )
    }

    static let clientCapabilities: JSONValue = .object([
        "fs": .object([
            "readTextFile": .bool(false),
            "writeTextFile": .bool(false),
        ]),
        "terminal": .bool(false),
        "session": .object([
            "configOptions": .object([
                "boolean": .object([:]),
            ]),
        ]),
        "plan": .object([:]),
        "auth": .object([
            "terminal": .bool(false),
        ]),
        "_meta": .object([
            "browser-auth-delegated": .bool(true),
        ]),
    ])

    func launchValidatedAuthenticationProcess(
        executable: VibeExecutable,
        workingDirectory: URL,
        processOptions: VibeProcessOptions = .init()
    ) async throws -> VibeValidatedTransport {
        let transport = transportFactory(.init(
            executableURL: executable.url,
            arguments: processOptions.arguments,
            workingDirectory: workingDirectory,
            environment: processOptions.environment
        ))
        do {
            let generation = try await transport.start()
            let compatibility = try await initializeAndValidate(
                transport: transport,
                executable: executable
            )
            return VibeValidatedTransport(
                transport: transport,
                generation: generation,
                compatibility: compatibility
            )
        } catch {
            _ = await transport.stop()
            throw error
        }
    }
}

public enum VibeAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDelegatedAuthenticationStart
    case invalidAuthenticationAttemptID
    case invalidDelegatedAuthenticationCompletion
    case invalidConfigurationRequest
    case invalidConfigurationResponse
    case invalidSessionListPagination(String)
    case sessionListPageLimitExceeded(maximumPages: Int)
    case savedSessionUnavailable(String)
    case unsupportedConfigurationOptionKind(String)

    public var description: String {
        switch self {
        case .invalidDelegatedAuthenticationStart:
            "Vibe returned an invalid delegated authentication start response"
        case .invalidAuthenticationAttemptID:
            "The delegated authentication attempt ID is invalid"
        case .invalidDelegatedAuthenticationCompletion:
            "Vibe returned an invalid delegated authentication completion response"
        case .invalidConfigurationRequest:
            "The Vibe configuration request is invalid"
        case .invalidConfigurationResponse:
            "Vibe returned an invalid configuration response"
        case let .invalidSessionListPagination(cursor):
            "Vibe repeated session/list cursor \(cursor)"
        case let .sessionListPageLimitExceeded(maximumPages):
            "Vibe session/list exceeded \(maximumPages) pages"
        case let .savedSessionUnavailable(sessionID):
            "Vibe has no persisted session matching \(sessionID)"
        case let .unsupportedConfigurationOptionKind(kind):
            "Vibe configuration option kind \(kind) is not writable"
        }
    }
}

public enum VibeAuthenticationState: Equatable, Sendable {
    case authenticated
    case unauthenticated
    case unknown(rawValue: String?)
}

public struct VibeAuthenticationStatus: Equatable, Sendable {
    public let state: VibeAuthenticationState
    public let reportedState: String?
    public let signOutAvailable: Bool?
    public let raw: JSONValue

    public var isAuthenticated: Bool? {
        switch state {
        case .authenticated: true
        case .unauthenticated: false
        case .unknown: nil
        }
    }

    public init(raw: JSONValue) {
        self.raw = raw
        let object = raw.objectValue
        let reportedState = object?["authState"]?.stringValue
            ?? object?["status"]?.stringValue
        self.reportedState = reportedState
        signOutAvailable = object?["signOutAvailable"]?.boolValue

        if let authenticated = object?["authenticated"]?.boolValue
            ?? object?["isAuthenticated"]?.boolValue
        {
            state = authenticated ? .authenticated : .unauthenticated
            return
        }

        switch reportedState?.lowercased() {
        case "authenticated", "ready": state = .authenticated
        case "signed_out", "signed-out", "unauthenticated", "not_authenticated":
            state = .unauthenticated
        default: state = .unknown(rawValue: reportedState)
        }
    }
}

public enum VibeRepositoryTrustState: Equatable, Sendable {
    case trusted
    case untrusted
    case unknown(rawValue: String?)
}

public struct VibeRepositoryTrustStatus: Equatable, Sendable {
    public let state: VibeRepositoryTrustState
    public let reportedState: String?
    public let options: [JSONValue]
    public let details: JSONValue?
    public let raw: JSONValue

    /// Vibe reports every undecided repository as `untrusted`, even when it
    /// found no project-controlled files that require a trust decision. The
    /// explicit `details: null` shape means the session may proceed with
    /// project configuration excluded. Missing or malformed details remain
    /// blocked defensively.
    public var allowsSessionStart: Bool {
        switch state {
        case .trusted:
            true
        case .untrusted:
            details == .null
        case .unknown:
            false
        }
    }

    public init(raw: JSONValue) {
        self.raw = raw
        let object = raw.objectValue
        let reportedState = object?["trust_status"]?.stringValue
            ?? object?["status"]?.stringValue
        self.reportedState = reportedState
        details = object?["details"]
        options = object?["options"]?.arrayValue
            ?? object?["details"]?["availableDecisions"]?.arrayValue
            ?? []

        if let trusted = object?["trusted"]?.boolValue
            ?? object?["isTrusted"]?.boolValue
        {
            state = trusted ? .trusted : .untrusted
            return
        }

        switch reportedState?.lowercased() {
        case "trusted", "session": state = .trusted
        case "untrusted": state = .untrusted
        default: state = .unknown(rawValue: reportedState)
        }
    }
}

public struct VibeDelegatedAuthenticationAttempt: Equatable, Sendable {
    public let id: String
    public let signInURL: URL
    public let expiresAt: String?
    public let raw: JSONValue
}

public struct VibeDelegatedAuthenticationCompletion: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case completed
        case unknown(String?)
    }

    public let attemptID: String
    public let state: State
    public let persistenceResult: JSONValue?
    public let raw: JSONValue
}

public struct VibeConfigurationOption: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case select
        case boolean
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "select": self = .select
            case "boolean": self = .boolean
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .select: "select"
            case .boolean: "boolean"
            case let .unknown(value): value
            }
        }
    }

    public struct Choice: Equatable, Sendable {
        public let value: JSONValue
        public let name: String?
        public let raw: JSONValue
    }

    public let id: String
    public let name: String?
    public let kind: Kind
    public let currentValue: JSONValue
    public let choices: [Choice]
    public let metadata: JSONValue?
    public let raw: JSONValue

    public var values: [JSONValue] { choices.map(\.value) }
    public var alternateValue: JSONValue? { values.first(where: { $0 != currentValue }) }

    public init?(_ raw: JSONValue) {
        guard
            let object = raw.objectValue,
            let id = object["id"]?.stringValue,
            !id.isEmpty,
            let currentValue = object["currentValue"],
            let rawKind = object["type"]?.stringValue
        else { return nil }

        let kind = Kind(rawValue: rawKind)
        let choices: [Choice]
        switch kind {
        case .select:
            guard let rawChoices = object["options"]?.arrayValue else { return nil }
            var decoded: [Choice] = []
            decoded.reserveCapacity(rawChoices.count)
            for rawChoice in rawChoices {
                guard
                    let choice = rawChoice.objectValue,
                    let value = choice["value"]
                else { return nil }
                decoded.append(Choice(
                    value: value,
                    name: choice["name"]?.stringValue,
                    raw: rawChoice
                ))
            }
            choices = decoded
        case .boolean:
            guard currentValue.boolValue != nil else { return nil }
            choices = [
                Choice(value: .bool(false), name: nil, raw: .bool(false)),
                Choice(value: .bool(true), name: nil, raw: .bool(true)),
            ]
        case .unknown:
            choices = []
        }

        self.id = id
        name = object["name"]?.stringValue
        self.kind = kind
        self.currentValue = currentValue
        self.choices = choices
        metadata = object["_meta"]
        self.raw = raw
    }
}

public struct VibeConfigurationWriteResult: Equatable, Sendable {
    public let options: [VibeConfigurationOption]
    public let metadata: JSONValue?
    public let raw: JSONValue
}

struct VibeProcessOptions: Sendable {
    let arguments: [String]
    let environment: [String: String]?

    init(arguments: [String] = [], environment: [String: String]? = nil) {
        self.arguments = arguments
        self.environment = environment
    }
}

struct VibeValidatedTransport: Sendable {
    let transport: ACPTransport
    let generation: UUID
    let compatibility: VibeCompatibility
}
