import Darwin
import Foundation

public struct CanonicalRepository: Equatable, Hashable, Sendable {
    public let path: String
    public let displayName: String

    init(path: String) {
        self.path = path
        let name = URL(filePath: path).lastPathComponent
        displayName = name.isEmpty ? path : name
    }
}

public enum RepositoryValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathDoesNotExist(String)
    case notDirectory(String)
    case canonicalizationFailed(path: String, reason: String)
    case gitUnavailable(String)
    case notWorktree(String)
    case bareRepository(String)
    case invalidHEAD(String)
    case gitFailure(arguments: [String], status: Int32, message: String)
    case invalidGitOutput(String)

    public var description: String {
        switch self {
        case let .pathDoesNotExist(path): "Repository path does not exist: \(path)"
        case let .notDirectory(path): "Repository path is not a directory: \(path)"
        case let .canonicalizationFailed(path, reason): "Could not canonicalize \(path): \(reason)"
        case let .gitUnavailable(path): "Git executable is unavailable at \(path)"
        case let .notWorktree(path): "Path is not inside a Git worktree: \(path)"
        case let .bareRepository(path): "Bare Git repositories are not supported: \(path)"
        case let .invalidHEAD(path): "Git worktree does not have a valid HEAD commit: \(path)"
        case let .gitFailure(arguments, status, message):
            "Git \(arguments.joined(separator: " ")) failed with status \(status): \(message)"
        case let .invalidGitOutput(message): "Git returned invalid repository metadata: \(message)"
        }
    }
}

/// Validates and canonicalizes repositories without mutating Git state.
public struct RepositoryValidator: Sendable {
    public let gitExecutableURL: URL

    public init(gitExecutableURL: URL = URL(filePath: "/usr/bin/git")) {
        self.gitExecutableURL = gitExecutableURL
    }

    public func validate(_ candidate: URL) throws -> CanonicalRepository {
        let candidatePath = candidate.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory) else {
            throw RepositoryValidationError.pathDoesNotExist(candidatePath)
        }
        guard isDirectory.boolValue else {
            throw RepositoryValidationError.notDirectory(candidatePath)
        }
        let canonicalCandidate = try canonicalPath(candidatePath)

        guard FileManager.default.isExecutableFile(atPath: gitExecutableURL.path) else {
            throw RepositoryValidationError.gitUnavailable(gitExecutableURL.path)
        }

        let flags = try runGit(
            ["rev-parse", "--is-inside-work-tree", "--is-bare-repository"],
            workingDirectory: URL(filePath: canonicalCandidate)
        ).split(whereSeparator: \Character.isNewline)
        guard flags.dropFirst().first == "false" else {
            throw RepositoryValidationError.bareRepository(canonicalCandidate)
        }
        guard flags.first == "true" else {
            throw RepositoryValidationError.notWorktree(canonicalCandidate)
        }

        do {
            _ = try runGit(
                ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
                workingDirectory: URL(filePath: canonicalCandidate)
            )
        } catch let error as RepositoryValidationError {
            if case .gitFailure = error {
                throw RepositoryValidationError.invalidHEAD(canonicalCandidate)
            }
            throw error
        }

        let topLevelOutput = try runGit(
            ["rev-parse", "--show-toplevel"],
            workingDirectory: URL(filePath: canonicalCandidate)
        )
        let topLevel = topLevelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topLevel.isEmpty else {
            throw RepositoryValidationError.invalidGitOutput("empty --show-toplevel response")
        }
        return CanonicalRepository(path: try canonicalPath(topLevel))
    }

    private func canonicalPath(_ path: String) throws -> String {
        errno = 0
        guard let resolved = realpath(path, nil) else {
            let code = errno
            throw RepositoryValidationError.canonicalizationFailed(
                path: path,
                reason: String(cString: strerror(code))
            )
        }
        defer { free(resolved) }
        let value = String(cString: resolved)
        if value == "/" { return value }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private func runGit(_ arguments: [String], workingDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
        ]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw RepositoryValidationError.gitUnavailable(gitExecutableURL.path)
        }
        process.waitUntilExit()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.prefix(8_192), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RepositoryValidationError.gitFailure(
                arguments: arguments,
                status: process.terminationStatus,
                message: message
            )
        }
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw RepositoryValidationError.invalidGitOutput("non-UTF-8 output")
        }
        return output
    }
}
