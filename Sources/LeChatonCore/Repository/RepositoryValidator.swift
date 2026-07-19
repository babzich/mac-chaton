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

public struct RepositoryValidationLimits: Equatable, Sendable {
    public let maximumOutputBytes: Int
    public let maximumOutputLines: Int
    public let commandTimeout: Duration

    public init(
        maximumOutputBytes: Int = 128 * 1_024,
        maximumOutputLines: Int = 2_000,
        commandTimeout: Duration = .seconds(10)
    ) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.maximumOutputLines = max(0, maximumOutputLines)
        self.commandTimeout = commandTimeout < .zero ? .zero : commandTimeout
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
    case gitTimedOut(arguments: [String])
    case gitOutputTooLarge(arguments: [String])
    case gitCleanupIncomplete(arguments: [String])
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
        case let .gitTimedOut(arguments):
            "Git \(arguments.joined(separator: " ")) timed out"
        case let .gitOutputTooLarge(arguments):
            "Git \(arguments.joined(separator: " ")) exceeded repository-validation output limits"
        case let .gitCleanupIncomplete(arguments):
            "Git \(arguments.joined(separator: " ")) left a process or descendant alive"
        case let .invalidGitOutput(message): "Git returned invalid repository metadata: \(message)"
        }
    }
}

/// Validates and canonicalizes repositories without mutating Git state.
public struct RepositoryValidator: Sendable {
    public let gitExecutableURL: URL
    public let limits: RepositoryValidationLimits
    private let runner: GitCommandRunner

    public init(
        gitExecutableURL: URL = URL(filePath: "/usr/bin/git"),
        limits: RepositoryValidationLimits = RepositoryValidationLimits()
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.limits = limits
        runner = GitCommandRunner(executableURL: gitExecutableURL)
    }

    public func validate(_ candidate: URL) async throws -> CanonicalRepository {
        try Task.checkCancellation()
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

        let flags = try await runGit(
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
            _ = try await runGit(
                ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
                workingDirectory: URL(filePath: canonicalCandidate)
            )
        } catch let error as RepositoryValidationError {
            if case .gitFailure = error {
                throw RepositoryValidationError.invalidHEAD(canonicalCandidate)
            }
            throw error
        }

        let topLevelOutput = try await runGit(
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

    private func runGit(_ arguments: [String], workingDirectory: URL) async throws -> String {
        try Task.checkCancellation()
        let result: GitCommandResult
        do {
            result = try await runner.run(
                arguments: arguments,
                workingDirectory: workingDirectory,
                maximumBytes: limits.maximumOutputBytes,
                maximumLines: limits.maximumOutputLines,
                timeout: limits.commandTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RepositoryValidationError.gitUnavailable(gitExecutableURL.path)
        }
        guard !result.leftDescendants else {
            throw RepositoryValidationError.gitCleanupIncomplete(arguments: arguments)
        }
        guard !result.timedOut else {
            throw RepositoryValidationError.gitTimedOut(arguments: arguments)
        }
        guard !result.truncated else {
            throw RepositoryValidationError.gitOutputTooLarge(arguments: arguments)
        }
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr.prefix(8_192), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RepositoryValidationError.gitFailure(
                arguments: arguments,
                status: result.exitCode,
                message: message
            )
        }
        guard !result.stdout.contains(0),
              let output = String(data: result.stdout, encoding: .utf8)
        else {
            throw RepositoryValidationError.invalidGitOutput("non-UTF-8 or NUL-containing output")
        }
        return output
    }
}
