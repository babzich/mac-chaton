import Darwin
import Foundation
import Testing
@testable import LeChatonCore

@Suite("Repository validation", .serialized)
struct RepositoryValidatorTests {
    @Test("Nested symlink paths resolve to the canonical repository root while dirty state is allowed")
    func canonicalizesNestedSymlinkAndAllowsDirtyState() async throws {
        let repository = try PersistenceTestSupport.makeRepository(name: "Project with spaces ü猫")
        let parent = repository.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }

        let trackedFile = repository.appending(path: "seed.txt")
        try Data("staged change\n".utf8).write(to: trackedFile)
        try PersistenceTestSupport.git(["add", "--", "seed.txt"], at: repository)
        try Data("staged change\nunstaged change\n".utf8).write(to: trackedFile)
        try Data("untracked\n".utf8).write(to: repository.appending(path: "new file é.txt"))

        let nestedDirectory = repository.appending(path: "Sources/Deep Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let symlink = parent.appending(path: "nested repository alias ☃", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: nestedDirectory)

        let status = try PersistenceTestSupport.git(
            ["-c", "core.quotepath=false", "status", "--porcelain"],
            at: repository
        )
        #expect(status.contains("MM seed.txt"))
        #expect(status.contains("?? "))
        #expect(status.contains("new file é.txt"))

        let result = try await RepositoryValidator().validate(URL(filePath: symlink.path + "/"))
        let expectedRoot = try canonicalPath(repository)
        #expect(result.path == expectedRoot)
        #expect(result.path.hasPrefix("/"))
        #expect(!result.path.hasSuffix("/"))
        #expect(result.displayName == "Project with spaces ü猫")
    }

    @Test("Missing paths, files, non-worktrees, bare repositories, and unborn HEADs are rejected")
    func rejectsInvalidRepositoryForms() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonRepositoryValidation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let validator = RepositoryValidator()

        let missing = scratch.appending(path: "missing", directoryHint: .isDirectory)
        await #expect(throws: RepositoryValidationError.pathDoesNotExist(missing.path)) {
            _ = try await validator.validate(missing)
        }

        let regularFile = scratch.appending(path: "not-a-directory.txt")
        try Data("file\n".utf8).write(to: regularFile)
        await #expect(throws: RepositoryValidationError.notDirectory(regularFile.path)) {
            _ = try await validator.validate(regularFile)
        }

        let nonWorktree = scratch.appending(path: "ordinary directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nonWorktree, withIntermediateDirectories: false)
        guard let nonWorktreeError = await validationError(for: nonWorktree, using: validator) else {
            return
        }
        guard case let .gitFailure(arguments, status, _) = nonWorktreeError else {
            Issue.record("Expected a Git rejection for a non-worktree, got \(String(describing: nonWorktreeError))")
            return
        }
        #expect(arguments == ["rev-parse", "--is-inside-work-tree", "--is-bare-repository"])
        #expect(status != 0)

        let bare = scratch.appending(path: "bare repository.git", directoryHint: .isDirectory)
        try PersistenceTestSupport.git(["init", "--bare", bare.path], at: scratch)
        let canonicalBarePath = try canonicalPath(bare)
        await #expect(throws: RepositoryValidationError.bareRepository(canonicalBarePath)) {
            _ = try await validator.validate(bare)
        }

        let unborn = scratch.appending(path: "unborn repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: false)
        try PersistenceTestSupport.git(["init"], at: unborn)
        let canonicalUnbornPath = try canonicalPath(unborn)
        await #expect(throws: RepositoryValidationError.invalidHEAD(canonicalUnbornPath)) {
            _ = try await validator.validate(unborn)
        }
    }

    @Test("A detached HEAD remains a valid committed worktree")
    func acceptsDetachedHEAD() async throws {
        let repository = try PersistenceTestSupport.makeRepository(name: "Detached HEAD")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let commit = try PersistenceTestSupport.git(["rev-parse", "HEAD"], at: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try PersistenceTestSupport.git(["checkout", "--detach", commit], at: repository)

        let result = try await RepositoryValidator().validate(repository)
        let expectedRoot = try canonicalPath(repository)
        #expect(result.path == expectedRoot)
    }

    @Test("A linked Git worktree with a valid HEAD is accepted as its own canonical root")
    func acceptsLinkedWorktree() async throws {
        let repository = try PersistenceTestSupport.makeRepository(name: "Primary worktree")
        let parent = repository.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let linked = parent.appending(path: "Linked worktree ü猫", directoryHint: .isDirectory)

        try PersistenceTestSupport.git(["worktree", "add", "--detach", linked.path], at: repository)

        let result = try await RepositoryValidator().validate(linked)
        let expectedRoot = try canonicalPath(linked)
        #expect(result.path == expectedRoot)
        #expect(result.displayName == "Linked worktree ü猫")
    }

    @Test("Validation fails with a typed error when Git output exceeds its bound")
    func boundsGitOutput() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let executable = try makeExecutable(
            in: scratch,
            body: "while :; do printf '012345678901234567890123456789\\n'; done"
        )
        let arguments = ["rev-parse", "--is-inside-work-tree", "--is-bare-repository"]
        let validator = RepositoryValidator(
            gitExecutableURL: executable,
            limits: .init(
                maximumOutputBytes: 64,
                maximumOutputLines: 4,
                commandTimeout: .seconds(2)
            )
        )

        guard let error = await validationError(for: scratch, using: validator) else { return }
        #expect(error == .gitOutputTooLarge(arguments: arguments))
    }

    @Test("A timed-out validation suspends instead of blocking the main actor")
    @MainActor
    func timeoutDoesNotBlockMainActor() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let executable = try makeExecutable(in: scratch, body: "/bin/sleep 60")
        let arguments = ["rev-parse", "--is-inside-work-tree", "--is-bare-repository"]
        let validator = RepositoryValidator(
            gitExecutableURL: executable,
            limits: .init(commandTimeout: .milliseconds(40))
        )
        var heartbeatObserved = false
        let heartbeat = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            heartbeatObserved = true
        }

        let error = await validationError(for: scratch, using: validator)
        await heartbeat.value

        #expect(heartbeatObserved)
        #expect(error == .gitTimedOut(arguments: arguments))
    }

    @Test("Cancelling validation cancels the Git subprocess operation")
    func cancellationIsPropagated() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let executable = try makeExecutable(in: scratch, body: "/bin/sleep 60")
        let validator = RepositoryValidator(
            gitExecutableURL: executable,
            limits: .init(commandTimeout: .seconds(10))
        )
        let validation = Task { try await validator.validate(scratch) }
        try await Task.sleep(for: .milliseconds(30))
        validation.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await validation.value
        }
    }

    private func validationError(
        for candidate: URL,
        using validator: RepositoryValidator
    ) async -> RepositoryValidationError? {
        do {
            _ = try await validator.validate(candidate)
            Issue.record("Expected repository validation to fail for \(candidate.path)")
            return nil
        } catch let error as RepositoryValidationError {
            return error
        } catch {
            Issue.record("Expected RepositoryValidationError, got \(error)")
            return nil
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonRepositoryValidatorFakeGit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let executable = directory.appending(path: "fake-git")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func canonicalPath(_ url: URL) throws -> String {
        errno = 0
        guard let resolved = realpath(url.path, nil) else {
            let status = errno
            throw RepositoryFixtureError.realpath(
                path: url.path,
                status: status,
                message: String(cString: strerror(status))
            )
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private enum RepositoryFixtureError: Error {
    case realpath(path: String, status: Int32, message: String)
}
