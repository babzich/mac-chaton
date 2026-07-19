import Foundation

public enum ProviderAuthMode: String, Equatable, Sendable {
    case bearer
    case keylessLoopback
}

public enum ManagedVibeProviderStatus: Equatable, Sendable {
    case configured
    case active
}

public struct ManagedVibeModel: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var modelID: String
    public var displayName: String

    public init(id: UUID = UUID(), modelID: String, displayName: String) {
        self.id = id
        self.modelID = modelID
        self.displayName = displayName
    }
}

public struct ManagedVibeProvider: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let authMode: ProviderAuthMode
    public let models: [ManagedVibeModel]
    public let status: ManagedVibeProviderStatus
    public let activeModelID: UUID?

    public init(
        id: UUID,
        name: String,
        baseURL: URL,
        authMode: ProviderAuthMode,
        models: [ManagedVibeModel],
        status: ManagedVibeProviderStatus,
        activeModelID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authMode = authMode
        self.models = models
        self.status = status
        self.activeModelID = activeModelID
    }
}

public struct ProviderDraft: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var authMode: ProviderAuthMode
    public var apiKey: String
    public var models: [ManagedVibeModel]

    public init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        authMode: ProviderAuthMode = .bearer,
        apiKey: String = "",
        models: [ManagedVibeModel] = [.init(modelID: "", displayName: "")]
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authMode = authMode
        self.apiKey = apiKey
        self.models = models
    }

    public init(provider: ManagedVibeProvider) {
        self.init(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL.absoluteString,
            authMode: provider.authMode,
            apiKey: "",
            models: provider.models
        )
    }
}

public struct ProviderTestResult: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let providerID: UUID
    public let testedAt: Date

    public init(id: UUID, providerID: UUID, testedAt: Date) {
        self.id = id
        self.providerID = providerID
        self.testedAt = testedAt
    }
}

public struct ProviderProbeRequest: Sendable {
    public let draft: ProviderDraft
    public let executable: VibeExecutable
    public let apiKeyEnvironmentName: String?

    public init(
        draft: ProviderDraft,
        executable: VibeExecutable,
        apiKeyEnvironmentName: String?
    ) {
        self.draft = draft
        self.executable = executable
        self.apiKeyEnvironmentName = apiKeyEnvironmentName
    }
}

public struct ProviderProbeClient: Sendable {
    public let run: @Sendable (ProviderProbeRequest) async throws -> Void

    public init(run: @escaping @Sendable (ProviderProbeRequest) async throws -> Void) {
        self.run = run
    }
}

public protocol ProviderSecretStore: Sendable {
    func read(account: String) async throws -> String?
    func write(_ secret: String, account: String) async throws
    func delete(account: String) async throws
}

public struct ProviderRuntimeEnvironment: Equatable, Sendable {
    public let name: String
    public let secret: String

    public init(name: String, secret: String) {
        self.name = name
        self.secret = secret
    }
}

public enum ManagedVibeProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName
    case invalidEndpoint
    case insecureRemoteEndpoint
    case endpointContainsCredentials
    case endpointContainsQueryOrFragment
    case keylessRequiresLoopback
    case missingAPIKey
    case missingModel
    case duplicateModelID(String)
    case malformedConfiguration
    case managedIdentifierCollision(String)
    case staleConfiguration
    case providerNotFound
    case modelNotFound
    case testRequired
    case testedDraftChanged
    case providerIsActive
    case activeModelRemoval
    case secretUnavailable

    public var description: String {
        switch self {
        case .invalidName: "Enter a provider name."
        case .invalidEndpoint: "Enter a valid absolute provider endpoint."
        case .insecureRemoteEndpoint: "Remote provider endpoints must use HTTPS."
        case .endpointContainsCredentials: "Provider endpoints cannot contain credentials."
        case .endpointContainsQueryOrFragment: "Provider endpoints cannot contain a query or fragment."
        case .keylessRequiresLoopback: "Keyless providers are limited to loopback endpoints."
        case .missingAPIKey: "Enter an API key, or retain the existing key while editing."
        case .missingModel: "Add at least one model ID."
        case let .duplicateModelID(id): "Model ID \(id) is duplicated."
        case .malformedConfiguration: "Vibe config.toml is malformed."
        case let .managedIdentifierCollision(identifier):
            "Vibe configuration already contains the reserved identifier \(identifier)."
        case .staleConfiguration:
            "Vibe configuration changed outside LeChaton. Reload Providers before saving."
        case .providerNotFound: "The provider no longer exists."
        case .modelNotFound: "The provider model no longer exists."
        case .testRequired: "Test this exact provider draft before saving it."
        case .testedDraftChanged: "The provider draft changed after its successful test. Test it again."
        case .providerIsActive: "Activate another model before removing this provider."
        case .activeModelRemoval: "Activate another model before removing the active model."
        case .secretUnavailable: "The provider credential is unavailable in Keychain."
        }
    }
}

enum ManagedProviderIdentifiers {
    static let prefix = "lechaton_"

    static func provider(_ id: UUID) -> String { prefix + compact(id) }
    static func model(_ id: UUID) -> String { prefix + compact(id) }
    static func key(providerID: UUID, keyID: UUID) -> String {
        "LECHATON_PROVIDER_\(compact(providerID).uppercased())_\(compact(keyID).uppercased())"
    }

    static func compact(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
