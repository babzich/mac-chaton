import Darwin
import Foundation
import Testing
@testable import LeChatonCore

@Suite("Repository validation", .serialized)
struct RepositoryValidatorTests {
    @Test("Nested symlink paths resolve to the canonical repository root while dirty state is allowed")
    func canonicalizesNestedSymlinkAndAllowsDirtyState() throws {
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

        let result = try RepositoryValidator().validate(URL(filePath: symlink.path + "/"))
        let expectedRoot = try canonicalPath(repository)
        #expect(result.path == expectedRoot)
        #expect(result.path.hasPrefix("/"))
        #expect(!result.path.hasSuffix("/"))
        #expect(result.displayName == "Project with spaces ü猫")
    }

    @Test("Missing paths, files, non-worktrees, bare repositories, and unborn HEADs are rejected")
    func rejectsInvalidRepositoryForms() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "LeChatonRepositoryValidation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let validator = RepositoryValidator()

        let missing = scratch.appending(path: "missing", directoryHint: .isDirectory)
        #expect(throws: RepositoryValidationError.pathDoesNotExist(missing.path)) {
            _ = try validator.validate(missing)
        }

        let regularFile = scratch.appending(path: "not-a-directory.txt")
        try Data("file\n".utf8).write(to: regularFile)
        #expect(throws: RepositoryValidationError.notDirectory(regularFile.path)) {
            _ = try validator.validate(regularFile)
        }

        let nonWorktree = scratch.appending(path: "ordinary directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nonWorktree, withIntermediateDirectories: false)
        guard let nonWorktreeError = validationError(for: nonWorktree, using: validator) else {
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
        #expect(throws: RepositoryValidationError.bareRepository(canonicalBarePath)) {
            _ = try validator.validate(bare)
        }

        let unborn = scratch.appending(path: "unborn repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: false)
        try PersistenceTestSupport.git(["init"], at: unborn)
        let canonicalUnbornPath = try canonicalPath(unborn)
        #expect(throws: RepositoryValidationError.invalidHEAD(canonicalUnbornPath)) {
            _ = try validator.validate(unborn)
        }
    }

    @Test("A detached HEAD remains a valid committed worktree")
    func acceptsDetachedHEAD() throws {
        let repository = try PersistenceTestSupport.makeRepository(name: "Detached HEAD")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let commit = try PersistenceTestSupport.git(["rev-parse", "HEAD"], at: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try PersistenceTestSupport.git(["checkout", "--detach", commit], at: repository)

        let result = try RepositoryValidator().validate(repository)
        let expectedRoot = try canonicalPath(repository)
        #expect(result.path == expectedRoot)
    }

    @Test("A linked Git worktree with a valid HEAD is accepted as its own canonical root")
    func acceptsLinkedWorktree() throws {
        let repository = try PersistenceTestSupport.makeRepository(name: "Primary worktree")
        let parent = repository.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let linked = parent.appending(path: "Linked worktree ü猫", directoryHint: .isDirectory)

        try PersistenceTestSupport.git(["worktree", "add", "--detach", linked.path], at: repository)

        let result = try RepositoryValidator().validate(linked)
        let expectedRoot = try canonicalPath(linked)
        #expect(result.path == expectedRoot)
        #expect(result.displayName == "Linked worktree ü猫")
    }

    private func validationError(
        for candidate: URL,
        using validator: RepositoryValidator
    ) -> RepositoryValidationError? {
        do {
            _ = try validator.validate(candidate)
            Issue.record("Expected repository validation to fail for \(candidate.path)")
            return nil
        } catch let error as RepositoryValidationError {
            return error
        } catch {
            Issue.record("Expected RepositoryValidationError, got \(error)")
            return nil
        }
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
