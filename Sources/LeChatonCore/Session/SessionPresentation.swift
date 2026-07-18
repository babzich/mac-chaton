import Foundation

public struct KnownGoodSnapshot: Equatable, Sendable {
    public let state: SessionState
    public let capturedAt: Date
    public let label: String

    public init(state: SessionState, capturedAt: Date = Date(), label: String = "Last known history") {
        self.state = state
        self.capturedAt = capturedAt
        self.label = label
    }
}

public struct PendingPermission: Equatable, Identifiable, Sendable {
    public let request: PermissionRequest

    public init(request: PermissionRequest) {
        self.request = request
    }

    public var id: RPCID { request.requestID }
}

public enum SessionAuthenticationPresentation: Equatable, Sendable {
    case unknown
    case status(VibeAuthenticationStatus)
}

public enum SessionTrustPresentation: Equatable, Sendable {
    case unknown
    case status(VibeRepositoryTrustStatus)
}

public enum ConfigurationApplicationState: Equatable, Sendable {
    case effectiveFromVibe
    case candidate(optionID: String, value: JSONValue)
    case applying(optionID: String, value: JSONValue)
    case reloadRequired(optionID: String, requestedValue: JSONValue)
}

public struct ExecutableCandidatePresentation: Equatable, Sendable {
    public let executable: VibeExecutable
    public let authentication: VibeAuthenticationStatus
    public let pendingSignIn: VibeDelegatedAuthenticationAttempt?

    public init(
        executable: VibeExecutable,
        authentication: VibeAuthenticationStatus,
        pendingSignIn: VibeDelegatedAuthenticationAttempt? = nil
    ) {
        self.executable = executable
        self.authentication = authentication
        self.pendingSignIn = pendingSignIn
    }
}

public enum SessionRecoveryAction: String, Equatable, Hashable, Sendable {
    case retry
    case resetRuntime
    case removeSavedThread
    case retryCleanup
    case retryCandidate
    case resetLocalMetadata
    case revealDatabase
    case exportDiagnostic
    case updateApplication
    case quit
}

public struct SessionModelIssue: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case runtime
        case persistence
        case repositoryUnavailable
        case authenticationRequired
        case trustRequired
        case cleanupRequired
        case swapFailed
        case database
        case configurationReloadRequired
    }

    public let kind: Kind
    public let title: String
    public let message: String
    public let actions: [SessionRecoveryAction]

    public init(
        kind: Kind,
        title: String,
        message: String,
        actions: [SessionRecoveryAction]
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }
}

public enum SessionModelError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidLifecycle(expected: String, actual: SessionLifecycle)
    case noSavedThread
    case noRuntime
    case staleRuntime
    case replayAttemptMismatch
    case replayBarrierTimeout
    case replayStreamEnded
    case cleanupIncomplete(Set<ProcessIdentity>)
    case cleanupOutstanding
    case authenticationRequired
    case repositoryTrustRequired
    case unsupportedTrustDecision(String)
    case unsupportedConfiguration(String)
    case configurationNotEffective(optionID: String, requested: JSONValue, effective: JSONValue?)
    case noExecutableCandidate
    case candidateAuthenticationRequired

    public var description: String {
        switch self {
        case let .invalidLifecycle(expected, actual):
            "Action requires \(expected); current lifecycle is \(actual)"
        case .noSavedThread: "No saved Thread is selected"
        case .noRuntime: "No session runtime is loaded"
        case .staleRuntime: "The session runtime was replaced while the action was in progress"
        case .replayAttemptMismatch: "Replay generation or load-attempt identifiers did not match"
        case .replayBarrierTimeout: "Replay did not reach its acknowledged barrier"
        case .replayStreamEnded: "The replay event stream ended before history was complete"
        case let .cleanupIncomplete(survivors):
            "Runtime cleanup left \(survivors.count) verified process survivor(s)"
        case .cleanupOutstanding: "A previous process owner still requires verified cleanup"
        case .authenticationRequired: "Vibe authentication is required"
        case .repositoryTrustRequired: "Repository trust must be resolved through Vibe"
        case let .unsupportedTrustDecision(decision):
            "Vibe did not advertise repository trust decision \(decision)"
        case let .unsupportedConfiguration(optionID):
            "Configuration option \(optionID) is unavailable or unsupported"
        case let .configurationNotEffective(optionID, requested, effective):
            "Vibe did not retain \(optionID)=\(requested); effective value is \(String(describing: effective))"
        case .noExecutableCandidate: "No validated executable candidate is available"
        case .candidateAuthenticationRequired: "The executable candidate is not authenticated"
        }
    }
}
