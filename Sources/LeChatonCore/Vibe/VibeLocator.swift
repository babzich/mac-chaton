import Darwin
import Foundation

public struct VibeExecutable: Equatable, Hashable, Sendable {
    public let url: URL
    public let source: Source

    public enum Source: Equatable, Hashable, Sendable {
        case explicit
        case storedPreference
        case standardLocation
    }
}

public enum VibeLocatorError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(searched: [String])
    case doesNotExist(String)
    case notRegularFile(String)
    case notExecutable(String)

    public var description: String {
        switch self {
        case let .notFound(searched): "vibe-acp was not found; searched: \(searched.joined(separator: ", "))"
        case let .doesNotExist(path): "vibe-acp does not exist at \(path)"
        case let .notRegularFile(path): "vibe-acp is not a regular file at \(path)"
        case let .notExecutable(path): "vibe-acp is not executable at \(path)"
        }
    }
}

/// UI-independent executable discovery. A picker remains app-owned.
public struct VibeLocator: Sendable {
    public let standardLocations: [URL]

    public init(standardLocations: [URL]? = nil) {
        self.standardLocations = standardLocations ?? [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/vibe-acp"),
            URL(filePath: "/opt/homebrew/bin/vibe-acp"),
            URL(filePath: "/usr/local/bin/vibe-acp"),
        ]
    }

    public func locate(explicitPath: String? = nil, storedPath: String? = nil) throws -> VibeExecutable {
        if let explicitPath, !explicitPath.isEmpty {
            return try validate(URL(filePath: explicitPath), source: .explicit)
        }
        if let storedPath, !storedPath.isEmpty {
            return try validate(URL(filePath: storedPath), source: .storedPreference)
        }
        for location in standardLocations where FileManager.default.fileExists(atPath: location.path) {
            return try validate(location, source: .standardLocation)
        }
        throw VibeLocatorError.notFound(searched: standardLocations.map(\.path))
    }

    public func validate(_ candidate: URL, source: VibeExecutable.Source = .explicit) throws -> VibeExecutable {
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else {
            throw VibeLocatorError.doesNotExist(canonical.path)
        }
        guard !isDirectory.boolValue else { throw VibeLocatorError.notRegularFile(canonical.path) }

        var statBuffer = stat()
        guard lstat(canonical.path, &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            throw VibeLocatorError.notRegularFile(canonical.path)
        }
        guard FileManager.default.isExecutableFile(atPath: canonical.path) else {
            throw VibeLocatorError.notExecutable(canonical.path)
        }
        return VibeExecutable(url: canonical, source: source)
    }
}

public struct VibeCompatibility: Equatable, Sendable {
    public static let supportedProtocolVersion = ACPProtocol.supportedVersion
    public static let supportedAgentName = "@mistralai/mistral-vibe"
    public static let supportedVersion = "2.21.0"
    public static let requiredCapabilities = ["loadSession", "sessionCapabilities.list"]

    public let executable: VibeExecutable
    public let initialization: ACPInitializeResult

    public init(executable: VibeExecutable, initialization: ACPInitializeResult) throws {
        guard initialization.protocolVersion == Self.supportedProtocolVersion else {
            throw VibeCompatibilityError.protocolVersion(
                expected: Self.supportedProtocolVersion,
                reported: initialization.protocolVersion
            )
        }
        guard let agentInfo = initialization.agentInfo else {
            throw VibeCompatibilityError.missingAgentInfo
        }
        guard agentInfo.name == Self.supportedAgentName else {
            throw VibeCompatibilityError.agentName(
                expected: Self.supportedAgentName,
                reported: agentInfo.name,
                executable: executable.url.path
            )
        }
        guard agentInfo.version == Self.supportedVersion else {
            throw VibeCompatibilityError.agentVersion(
                expected: Self.supportedVersion,
                reported: agentInfo.version,
                executable: executable.url.path
            )
        }
        guard initialization.agentCapabilities["loadSession"]?.boolValue == true else {
            throw VibeCompatibilityError.missingRequiredCapability(
                "loadSession",
                executable: executable.url.path
            )
        }
        guard initialization.agentCapabilities["sessionCapabilities"]?["list"]?.objectValue != nil else {
            throw VibeCompatibilityError.missingRequiredCapability(
                "sessionCapabilities.list",
                executable: executable.url.path
            )
        }
        self.executable = executable
        self.initialization = initialization
    }
}

public enum VibeCompatibilityError: Error, Equatable, Sendable, CustomStringConvertible {
    case protocolVersion(expected: Int, reported: Int)
    case missingAgentInfo
    case agentName(expected: String, reported: String, executable: String)
    case agentVersion(expected: String, reported: String, executable: String)
    case missingRequiredCapability(String, executable: String)

    public var description: String {
        switch self {
        case let .protocolVersion(expected, reported):
            "Unsupported ACP protocol: expected \(expected), reported \(reported)"
        case .missingAgentInfo:
            "Vibe initialize response did not include agentInfo"
        case let .agentName(expected, reported, executable):
            "Unsupported ACP agent at \(executable): expected \(expected), reported \(reported)"
        case let .agentVersion(expected, reported, executable):
            "Unsupported Vibe version at \(executable): expected \(expected), reported \(reported)"
        case let .missingRequiredCapability(capability, executable):
            "Vibe at \(executable) did not negotiate required capability \(capability)=true"
        }
    }
}
